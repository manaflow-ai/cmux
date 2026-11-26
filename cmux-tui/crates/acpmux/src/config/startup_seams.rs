//! Counts work for one scratch tree, including its list workers. Other tests' trees are separate.

use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex};

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Ancestors,
    Sync,
}

struct Counter {
    root: PathBuf,
    kind: Kind,
    count: Arc<AtomicUsize>,
}

static COUNTERS: Mutex<Vec<Counter>> = Mutex::new(Vec::new());

pub(crate) struct Count(Arc<AtomicUsize>);

impl Count {
    fn new(root: &Path, kind: Kind) -> Self {
        let count = Arc::new(AtomicUsize::new(0));
        COUNTERS.lock().unwrap().push(Counter {
            root: root.to_path_buf(),
            kind,
            count: count.clone(),
        });
        Self(count)
    }

    pub(crate) fn ancestors(root: &Path) -> Self {
        Self::new(root, Kind::Ancestors)
    }

    pub(crate) fn syncs(root: &Path) -> Self {
        Self::new(root, Kind::Sync)
    }

    pub(crate) fn get(&self) -> usize {
        self.0.load(Ordering::Relaxed)
    }
}

impl Drop for Count {
    fn drop(&mut self) {
        COUNTERS.lock().unwrap().retain(|counter| !Arc::ptr_eq(&counter.count, &self.0));
    }
}

fn note(path: &Path, kind: Kind) {
    for counter in COUNTERS.lock().unwrap().iter() {
        if counter.kind == kind && path.starts_with(&counter.root) {
            counter.count.fetch_add(1, Ordering::Relaxed);
        }
    }
}

pub(crate) fn ancestor_check(path: &Path) {
    note(path, Kind::Ancestors);
}

pub(crate) fn sync(path: &Path) {
    note(path, Kind::Sync);
}

thread_local! {
    static DIR_CHECKED: std::cell::RefCell<Option<DirChecked>> = const { std::cell::RefCell::new(None) };
}

type DirChecked = std::rc::Rc<dyn Fn(&Path)>;

/// Forces a replacement after permission checks and before the identity is checked again.
pub(crate) fn on_dir_checked(hook: impl Fn(&Path) + 'static) -> DirCheckGuard {
    DIR_CHECKED.with(|slot| *slot.borrow_mut() = Some(std::rc::Rc::new(hook)));
    DirCheckGuard
}

#[must_use = "the hook is taken off when the guard drops"]
pub(crate) struct DirCheckGuard;

impl Drop for DirCheckGuard {
    fn drop(&mut self) {
        drop(DIR_CHECKED.with(|slot| slot.borrow_mut().take()));
    }
}

pub(crate) fn dir_checked(path: &Path) {
    if let Some(hook) = DIR_CHECKED.with(|slot| slot.borrow().clone()) {
        hook(path);
    }
}

thread_local! {
    static DIRECTORY_ERROR: std::cell::Cell<Option<std::io::ErrorKind>> = const { std::cell::Cell::new(None) };
}

/// Makes one directory enumeration fail at EOF, after any names it already read.
pub(crate) fn on_directory_read_error(kind: std::io::ErrorKind) -> DirectoryErrorGuard {
    DIRECTORY_ERROR.with(|slot| slot.set(Some(kind)));
    DirectoryErrorGuard
}

#[must_use = "the hook is taken off when the guard drops"]
pub(crate) struct DirectoryErrorGuard;

impl Drop for DirectoryErrorGuard {
    fn drop(&mut self) {
        DIRECTORY_ERROR.with(|slot| slot.set(None));
    }
}

pub(crate) fn directory_read_error(error: Option<std::io::Error>) -> Option<std::io::Error> {
    error.or_else(|| DIRECTORY_ERROR.with(|slot| slot.take()).map(std::io::Error::from))
}

static ENTRY_STAT_ERRORS: Mutex<Vec<(PathBuf, i32)>> = Mutex::new(Vec::new());

/// Fails one entry's stat in either the listing thread or a worker for this scratch tree.
pub(crate) fn on_entry_stat_error(path: &Path, code: i32) -> EntryStatErrorGuard {
    ENTRY_STAT_ERRORS.lock().unwrap().push((path.to_path_buf(), code));
    EntryStatErrorGuard(path.to_path_buf())
}

#[must_use = "the hook is taken off when the guard drops"]
pub(crate) struct EntryStatErrorGuard(PathBuf);

impl Drop for EntryStatErrorGuard {
    fn drop(&mut self) {
        ENTRY_STAT_ERRORS.lock().unwrap().retain(|(path, _)| path != &self.0);
    }
}

pub(crate) fn entry_stat_error(path: &Path) -> std::io::Result<()> {
    match ENTRY_STAT_ERRORS.lock().unwrap().iter().find(|(entry, _)| entry == path) {
        Some((_, code)) => Err(std::io::Error::from_raw_os_error(*code)),
        None => Ok(()),
    }
}
