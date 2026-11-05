//! The wasmtime host: one slot holding the current module, swapped whole between calls.
//!
//! - **Load** (the watcher thread, never a caller): read the file, check where it comes from
//!   ([`crate::trust`]), compile it, link every import as a trap, instantiate it once and ask its
//!   `abi-version`. Only then does it go live, by one pointer store ([`ArcSwapOption`]).
//! - **Call** (any thread, lock-free): each thread keeps its own instance of the current module and
//!   makes a new one when the module changed since its last call. A call in flight keeps the
//!   instance it started on, so a swap never stops or waits for one.
//! - **Trap** (an `unreachable`, a panic, fuel or memory past the limit, a bad export): the call
//!   answers `None` (the caller runs native code), the instance is dropped, and the slot goes back
//!   to the module before this one, or to none. The trapped bytes are not loaded again until the
//!   file changes to other bytes.

use crate::{ABI_VERSION, Agent, Offer};
use arc_swap::ArcSwapOption;
use sha2::Digest as _;
use std::cell::RefCell;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicU64, Ordering};
use std::sync::{Arc, Mutex, OnceLock, Weak};
use std::time::{Duration, Instant, SystemTime};
use wasmtime::component::{Component, InstancePre, Linker};
use wasmtime::{Config, Engine, Store, StoreLimits, StoreLimitsBuilder};

mod bindings {
    wasmtime::component::bindgen!({ path: "wit", world: "hot" });
}

/// How a slot runs its modules.
#[derive(Debug, Clone, Copy)]
pub struct Options {
    /// Fuel per call (about one unit per wasm instruction); `None` runs without metering, so a
    /// guest that loops never returns. The daemon always meters.
    pub fuel_per_call: Option<u64>,
    /// The most linear memory one instance may grow to.
    pub memory_bytes: usize,
}

impl Default for Options {
    fn default() -> Self {
        // Reading a 64 KiB sign-in log takes about 2 M units; 200 M is ~0.1 s of a runaway loop.
        Self { fuel_per_call: Some(200_000_000), memory_bytes: 64 << 20 }
    }
}

/// What one load did and how long each step took.
#[derive(Debug, Clone)]
pub struct SwapReport {
    pub generation: u64,
    pub sha256: String,
    pub bytes: usize,
    pub read: Duration,
    pub compile: Duration,
    pub probe: Duration,
    /// The pointer store that makes it live.
    pub publish: Duration,
}

/// Counts since the slot was made.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct Stats {
    pub wasm_calls: u64,
    pub fallbacks: u64,
    pub traps: u64,
    pub swaps: u64,
    pub rollbacks: u64,
    pub refused: u64,
}

struct StoreData {
    limits: StoreLimits,
}

struct Loaded {
    generation: u64,
    sha256: String,
    pre: InstancePre<StoreData>,
}

#[derive(Default)]
struct Writer {
    /// The module before the current one: where a trap rolls back to.
    previous: Option<Arc<Loaded>>,
    /// Bytes that trapped or failed to load; skipped until the file holds other bytes.
    refused: Option<String>,
}

#[derive(Default)]
struct Counters {
    wasm_calls: AtomicU64,
    fallbacks: AtomicU64,
    traps: AtomicU64,
    swaps: AtomicU64,
    rollbacks: AtomicU64,
    refused: AtomicU64,
}

struct Shared {
    engine: Engine,
    path: PathBuf,
    options: Options,
    current: ArcSwapOption<Loaded>,
    writer: Mutex<Writer>,
    counters: Counters,
}

/// Generations are unique across every slot in the process, so a thread's cached instance is
/// keyed by its generation alone.
static NEXT_GENERATION: AtomicU64 = AtomicU64::new(1);

struct Cached {
    generation: u64,
    store: Store<StoreData>,
    hot: bindings::Hot,
}

thread_local! {
    static CACHED: RefCell<Option<Cached>> = const { RefCell::new(None) };
}

/// A hot-swappable module slot for one file.
#[derive(Clone)]
pub struct HotModule(Arc<Shared>);

/// The daemon's slot: `ACPMUX_HOT_MODULE` names the file, in a debug build only (a release build
/// answers `None` whatever the environment says). The first call starts the watcher, which loads
/// the file in the background; until then every call runs native code.
pub fn daemon() -> Option<&'static HotModule> {
    static SLOT: OnceLock<Option<HotModule>> = OnceLock::new();
    SLOT.get_or_init(|| {
        if !cfg!(debug_assertions) {
            return None;
        }
        let path = std::env::var_os(crate::ENV)?;
        match HotModule::new(Path::new(&path), Options::default()) {
            Ok(slot) => {
                slot.watch(Duration::from_millis(100));
                Some(slot)
            }
            Err(e) => {
                eprintln!("acpmux-hot: not loading {}: {e}", Path::new(&path).display());
                None
            }
        }
    })
    .as_ref()
}

impl HotModule {
    /// A slot for `path` (checked by [`crate::trust`]), empty until [`Self::reload`] or the
    /// watcher loads it.
    pub fn new(path: &Path, options: Options) -> Result<Self, String> {
        let path = crate::trust::check(path)?;
        let mut config = Config::new();
        config.consume_fuel(options.fuel_per_call.is_some());
        let engine = Engine::new(&config).map_err(|e| format!("wasmtime engine: {e}"))?;
        Ok(Self(Arc::new(Shared {
            engine,
            path,
            options,
            current: ArcSwapOption::empty(),
            writer: Mutex::new(Writer::default()),
            counters: Counters::default(),
        })))
    }

    pub fn path(&self) -> &Path {
        &self.0.path
    }

    /// The live module's sha256, if one is live.
    pub fn live(&self) -> Option<String> {
        self.0.current.load().as_ref().map(|l| l.sha256.clone())
    }

    pub fn stats(&self) -> Stats {
        let c = &self.0.counters;
        Stats {
            wasm_calls: c.wasm_calls.load(Ordering::Relaxed),
            fallbacks: c.fallbacks.load(Ordering::Relaxed),
            traps: c.traps.load(Ordering::Relaxed),
            swaps: c.swaps.load(Ordering::Relaxed),
            rollbacks: c.rollbacks.load(Ordering::Relaxed),
            refused: c.refused.load(Ordering::Relaxed),
        }
    }

    /// Loads the file now and makes it live (on the calling thread: the watcher's, or a bench's).
    /// `Ok(None)` when the file holds the live bytes or bytes already refused.
    pub fn reload(&self) -> Result<Option<SwapReport>, String> {
        let shared = &self.0;
        let started = Instant::now();
        let path = crate::trust::check(&shared.path)?;
        let bytes = std::fs::read(&path).map_err(|e| format!("{}: {e}", path.display()))?;
        let read = started.elapsed();
        let sha256 = hex::encode(sha2::Sha256::digest(&bytes));
        if self.live().as_deref() == Some(sha256.as_str())
            || lock(&shared.writer).refused.as_deref() == Some(sha256.as_str())
        {
            return Ok(None);
        }
        let refuse = |why: String| {
            lock(&shared.writer).refused = Some(sha256.clone());
            shared.counters.refused.fetch_add(1, Ordering::Relaxed);
            Err(format!("refused {}: {why}", &sha256[..12]))
        };
        let compiling = Instant::now();
        let component = match Component::new(&shared.engine, &bytes) {
            Ok(c) => c,
            Err(e) => return refuse(format!("compile: {e}")),
        };
        let mut linker = Linker::new(&shared.engine);
        // No capability: whatever the toolchain imports (WASI's stdio, clocks, environment)
        // traps if the guest ever calls it.
        if let Err(e) = linker.define_unknown_imports_as_traps(&component) {
            return refuse(format!("link: {e}"));
        }
        let pre = match linker.instantiate_pre(&component) {
            Ok(p) => p,
            Err(e) => return refuse(format!("link: {e}")),
        };
        let compile = compiling.elapsed();
        let probing = Instant::now();
        let generation = NEXT_GENERATION.fetch_add(1, Ordering::Relaxed);
        let loaded = Arc::new(Loaded { generation, sha256: sha256.clone(), pre });
        match instantiate(shared, &loaded).and_then(|mut c| {
            arm(shared, &mut c.store)?;
            c.hot.call_abi_version(&mut c.store)
        }) {
            Ok(ABI_VERSION) => {}
            Ok(other) => {
                return refuse(format!("abi-version {other}, this host speaks {ABI_VERSION}"));
            }
            Err(e) => return refuse(format!("probe: {e}")),
        }
        let probe = probing.elapsed();
        let publishing = Instant::now();
        {
            let mut writer = lock(&shared.writer);
            writer.previous = shared.current.swap(Some(loaded));
        }
        let publish = publishing.elapsed();
        shared.counters.swaps.fetch_add(1, Ordering::Relaxed);
        eprintln!(
            "acpmux-hot: live {} (gen {generation}, {} B, compile {compile:?}, probe {probe:?})",
            &sha256[..12],
            bytes.len()
        );
        Ok(Some(SwapReport {
            generation,
            sha256,
            bytes: bytes.len(),
            read,
            compile,
            probe,
            publish,
        }))
    }

    /// Watches the file from a background thread, polling its size, mtime and inode every `every`,
    /// and reloads when one changes. The thread ends when the last handle to the slot is dropped.
    pub fn watch(&self, every: Duration) -> std::thread::JoinHandle<()> {
        let weak: Weak<Shared> = Arc::downgrade(&self.0);
        std::thread::Builder::new()
            .name("acpmux-hot-watch".into())
            .spawn(move || {
                let mut last = None;
                loop {
                    let Some(shared) = weak.upgrade() else { return };
                    let now = stamp(&shared.path);
                    if now.is_some() && now != last {
                        last = now;
                        if let Err(e) = HotModule(shared).reload() {
                            eprintln!("acpmux-hot: {e}");
                        }
                    }
                    std::thread::sleep(every);
                }
            })
            .expect("spawn acpmux-hot-watch")
    }

    /// `write_journal::classify::is_pure_read` from the live module; `None`: run native code.
    pub fn is_pure_read(&self, command: &str) -> Option<bool> {
        self.call(|store, hot| hot.call_is_pure_read(store, command))
    }

    /// `agent_login::parse::offer` from the live module; `None`: run native code.
    pub fn login_offer(&self, agent: Agent, output: &str) -> Option<Option<Offer>> {
        let agent = match agent {
            Agent::Claude => bindings::Agent::Claude,
            Agent::Codex => bindings::Agent::Codex,
        };
        self.call(|store, hot| hot.call_login_offer(store, agent, output))
            .map(|offer| offer.map(|o| Offer { url: o.url, user_code: o.user_code }))
    }

    fn call<R>(
        &self,
        f: impl FnOnce(&mut Store<StoreData>, &bindings::Hot) -> wasmtime::Result<R>,
    ) -> Option<R> {
        let shared = &self.0;
        let Some(loaded) = shared.current.load_full() else {
            shared.counters.fallbacks.fetch_add(1, Ordering::Relaxed);
            return None;
        };
        let answer = CACHED.with(|cell| {
            let mut cached = cell.borrow_mut();
            if cached.as_ref().map(|c| c.generation) != Some(loaded.generation) {
                *cached = Some(instantiate(shared, &loaded)?);
            }
            let Some(c) = cached.as_mut() else { unreachable!("set above") };
            arm(shared, &mut c.store)?;
            let answer = f(&mut c.store, &c.hot);
            if answer.is_err() {
                // A trapped instance may be half-way through anything: never call it again.
                *cached = None;
            }
            answer
        });
        match answer {
            Ok(r) => {
                shared.counters.wasm_calls.fetch_add(1, Ordering::Relaxed);
                Some(r)
            }
            Err(e) => {
                self.trapped(&loaded, &e);
                shared.counters.fallbacks.fetch_add(1, Ordering::Relaxed);
                None
            }
        }
    }

    /// Rolls the slot back from `loaded` to the module before it, if `loaded` is still live.
    fn trapped(&self, loaded: &Arc<Loaded>, error: &wasmtime::Error) {
        let shared = &self.0;
        shared.counters.traps.fetch_add(1, Ordering::Relaxed);
        let mut writer = lock(&shared.writer);
        writer.refused = Some(loaded.sha256.clone());
        let live = shared.current.load();
        if live.as_ref().map(|l| l.generation) != Some(loaded.generation) {
            return;
        }
        drop(live);
        let back = writer.previous.take();
        let to = back.as_ref().map_or_else(|| "native".to_owned(), |b| b.sha256[..12].to_owned());
        shared.current.store(back);
        shared.counters.rollbacks.fetch_add(1, Ordering::Relaxed);
        eprintln!("acpmux-hot: {} trapped ({error}); rolled back to {to}", &loaded.sha256[..12]);
    }
}

fn instantiate(shared: &Shared, loaded: &Loaded) -> wasmtime::Result<Cached> {
    let limits = StoreLimitsBuilder::new().memory_size(shared.options.memory_bytes).build();
    let mut store = Store::new(&shared.engine, StoreData { limits });
    store.limiter(|d| &mut d.limits);
    arm(shared, &mut store)?;
    let instance = loaded.pre.instantiate(&mut store)?;
    let hot = bindings::Hot::new(&mut store, &instance)?;
    Ok(Cached { generation: loaded.generation, store, hot })
}

/// A full tank of fuel for the next call.
fn arm(shared: &Shared, store: &mut Store<StoreData>) -> wasmtime::Result<()> {
    match shared.options.fuel_per_call {
        Some(fuel) => store.set_fuel(fuel),
        None => Ok(()),
    }
}

fn lock<T>(m: &Mutex<T>) -> std::sync::MutexGuard<'_, T> {
    m.lock().unwrap_or_else(|e| e.into_inner())
}

fn stamp(path: &Path) -> Option<(u64, Option<SystemTime>, u64)> {
    let meta = std::fs::metadata(path).ok()?;
    #[cfg(unix)]
    let ino = std::os::unix::fs::MetadataExt::ino(&meta);
    #[cfg(not(unix))]
    let ino = 0;
    Some((meta.len(), meta.modified().ok(), ino))
}
