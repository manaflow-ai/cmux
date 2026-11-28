//! optchat-core as WebAssembly, for the hosted placement (a MemoryDO per
//! agent; plans/cmux-next/optchat.md section 4, decision O1). The JavaScript
//! host keeps messages and node texts in DO SQLite and passes a store object
//! with two methods:
//!
//! - `message(i: number): { kind: string, text: string }`
//! - `node(l: number, i: number): string | undefined`
//!
//! Results that are not plain values come back as JSON text. Ids are JS
//! numbers (exact below 2^53, far beyond any chat); one that is not a
//! non-negative integer is refused, never cast.
//!
//! A store method that throws, or a message that is not `{kind, text}` with a
//! known kind, is a failed read: the core never builds or starts a node from
//! it (`Store::failed`), and the call throws the read's error to JS with the
//! core state unchanged by it. The next `pump` reads again.

use optchat_core::{self as core, Checkpoint, CompactPrompt, Kind, Memory, NodeId, Store, Work};
use serde::Serialize;
use wasm_bindgen::prelude::*;

#[wasm_bindgen]
extern "C" {
    /// The host's store object.
    pub type JsStore;
    #[wasm_bindgen(method, catch)]
    fn message(this: &JsStore, i: f64) -> Result<JsValue, JsValue>;
    #[wasm_bindgen(method, catch)]
    fn node(this: &JsStore, l: u32, i: f64) -> Result<Option<String>, JsValue>;
    /// The stored ISO time of message `i` (the `date` tool); optional.
    #[wasm_bindgen(method, catch, js_name = date)]
    fn date_of(this: &JsStore, i: f64) -> Result<Option<String>, JsValue>;
}

#[derive(serde::Deserialize)]
struct JsMessage {
    kind: String,
    text: String,
}

/// Adapts the JS store to the core's `Store`, keeping the first failed read.
struct Host<'a> {
    store: &'a JsStore,
    error: std::cell::RefCell<Option<String>>,
}

impl<'a> Host<'a> {
    fn new(store: &'a JsStore) -> Host<'a> {
        Host {
            store,
            error: std::cell::RefCell::new(None),
        }
    }

    fn fail(&self, why: String) {
        self.error.borrow_mut().get_or_insert(why);
    }

    /// The first failed read, as the error the call throws.
    fn check(&self) -> Result<(), JsError> {
        match self.error.borrow().as_ref() {
            Some(why) => Err(JsError::new(why)),
            None => Ok(()),
        }
    }
}

fn describe(e: &JsValue) -> String {
    js_string(e)
}

impl Store for Host<'_> {
    fn message(&self, i: u64) -> (Kind, String) {
        let parsed = match self.store.message(i as f64) {
            Ok(value) => serde_json::from_str::<JsMessage>(&js_json(&value))
                .map_err(|e| format!("message {i} is not {{kind, text}}: {e}"))
                .and_then(|m| match Kind::parse(&m.kind) {
                    Some(kind) => Ok((kind, m.text)),
                    None => Err(format!("message {i} has an unknown kind {:?}", m.kind)),
                }),
            Err(e) => Err(format!("reading message {i} failed: {}", describe(&e))),
        };
        parsed.unwrap_or_else(|why| {
            self.fail(why);
            // A stand-in the core never builds from (it checks `failed`).
            (Kind::Note, String::new())
        })
    }
    fn node(&self, id: NodeId) -> Option<String> {
        self.store.node(id.l, id.i as f64).unwrap_or_else(|e| {
            self.fail(format!(
                "reading node {} failed: {}",
                id.name(),
                describe(&e)
            ));
            None
        })
    }
    fn failed(&self) -> bool {
        self.error.borrow().is_some()
    }
}

/// A JS number as an id: a finite, non-negative integer within 2^53.
fn id(x: f64) -> Result<u64, JsError> {
    check_id(x).map_err(|e| JsError::new(&e))
}

fn check_id(x: f64) -> Result<u64, String> {
    if x.is_finite() && x >= 0.0 && x.fract() == 0.0 && x <= 9_007_199_254_740_991.0 {
        Ok(x as u64)
    } else {
        Err(format!("{x} is not a message id (a non-negative integer)"))
    }
}

/// Byte offsets into `text` as JavaScript string indices (UTF-16 code
/// units), where a JS caller slices the text it got.
fn js_offsets(text: &str, marks: &[usize]) -> Vec<usize> {
    marks
        .iter()
        .map(|&m| text.get(..m).map_or(0, |head| head.encode_utf16().count()))
        .collect()
}

/// A level: below 64, as every stored node has.
fn level(l: u32) -> Result<u32, JsError> {
    check_level(l).map_err(|e| JsError::new(&e))
}

fn check_level(l: u32) -> Result<u32, String> {
    if l < 64 {
        Ok(l)
    } else {
        Err(format!("{l} is not a tree level"))
    }
}

#[wasm_bindgen]
extern "C" {
    #[wasm_bindgen(js_namespace = JSON, js_name = stringify)]
    fn json_stringify(value: &JsValue) -> String;
    /// `String(value)`: an Error shows as "Error: message" (JSON shows `{}`).
    #[wasm_bindgen(js_name = String)]
    fn js_string(value: &JsValue) -> String;
}

fn js_json(value: &JsValue) -> String {
    json_stringify(value)
}

#[derive(Serialize)]
#[serde(tag = "kind", rename_all = "lowercase")]
enum WorkJson {
    Free { l: u32, i: u64, text: String },
    Model { l: u32, i: u64 },
}

#[derive(Serialize)]
struct NodeJson {
    l: u32,
    i: u64,
    name: String,
}

/// One agent's memory state in the MemoryDO.
#[wasm_bindgen]
pub struct OptChat {
    memory: Memory,
}

#[wasm_bindgen]
impl OptChat {
    /// A new, empty memory with a view budget in bytes (`VIEW` when 0).
    #[wasm_bindgen(constructor)]
    pub fn new(budget: u32) -> OptChat {
        let budget = if budget == 0 {
            core::VIEW
        } else {
            budget as usize
        };
        OptChat {
            memory: Memory::new(budget),
        }
    }

    /// Rebuilds after a restart: `t` messages and the built nodes as JSON
    /// `[[l, i, bytes], ...]`.
    pub fn load(t: f64, built_json: &str, budget: u32) -> Result<OptChat, JsError> {
        let built: Vec<(u32, u64, usize)> = serde_json::from_str(built_json)?;
        if let Some((l, _, _)) = built.iter().find(|(l, _, _)| *l >= 64) {
            return Err(JsError::new(&format!("{l} is not a tree level")));
        }
        let budget = if budget == 0 {
            core::VIEW
        } else {
            budget as usize
        };
        Ok(OptChat {
            memory: Memory::load(
                id(t)?,
                built.into_iter().map(|(l, i, n)| (NodeId::new(l, i), n)),
                budget,
            ),
        })
    }

    /// Picks up from `checkpoint()`'s JSON without reading the whole log (spec 3.2: the saved view is
    /// loaded, never rebuilt): `t` messages, and the frontier as JSON `[[l, i, bytes], ...]` (every stored
    /// node at or above the checkpoint's `low` of its level). Messages after the checkpoint are appended
    /// as live. The result is lazy: change it with `appendIn` and `completeIn`. Undefined when the
    /// checkpoint does not fit the store (the host then folds with `load` + `makeLazy`).
    pub fn resume(
        checkpoint: &str,
        t: f64,
        frontier_json: &str,
        budget: u32,
        store: &JsStore,
    ) -> Result<Option<OptChat>, JsError> {
        let Some(c) = decode_checkpoint(checkpoint) else {
            return Ok(None);
        };
        let frontier: Vec<(u32, u64, usize)> = serde_json::from_str(frontier_json)?;
        if let Some((l, _, _)) = frontier.iter().find(|(l, _, _)| *l >= 64) {
            return Err(JsError::new(&format!("{l} is not a tree level")));
        }
        let budget = if budget == 0 {
            core::VIEW
        } else {
            budget as usize
        };
        let host = Host::new(store);
        let memory = Memory::resume(
            &c,
            id(t)?,
            frontier.into_iter().map(|(l, i, n)| (NodeId::new(l, i), n)),
            budget,
            &host,
        );
        host.check()?;
        Ok(memory.map(|memory| OptChat { memory }))
    }

    /// Where the memory stands, as JSON for `resume`: `{t, low, view, compact_view, merging, compact_merging}`.
    pub fn checkpoint(&self) -> String {
        encode_checkpoint(&self.memory.checkpoint())
    }

    /// Drops the sizes of nodes outside the views (read from the store when needed); from here on
    /// change it with `appendIn` and `completeIn`.
    #[wasm_bindgen(js_name = makeLazy)]
    pub fn make_lazy(&mut self) {
        self.memory.make_lazy();
    }

    #[wasm_bindgen(js_name = isLazy)]
    pub fn is_lazy(&self) -> bool {
        self.memory.is_lazy()
    }

    /// Appends one message (already stored) and returns its id. Not for a lazy memory (`appendIn`).
    pub fn append(&mut self) -> Result<f64, JsError> {
        if self.memory.is_lazy() {
            return Err(JsError::new("a lazy memory appends with appendIn"));
        }
        Ok(self.memory.append() as f64)
    }

    /// `append` for any memory: sizes it does not hold come from `store`.
    #[wasm_bindgen(js_name = appendIn)]
    pub fn append_in(&mut self, store: &JsStore) -> Result<f64, JsError> {
        let host = Host::new(store);
        let at = self.memory.append_in(&host);
        host.check()?;
        Ok(at as f64)
    }

    /// `complete` for any memory: sizes it does not hold come from `store`.
    #[wasm_bindgen(js_name = completeIn)]
    pub fn complete_in(
        &mut self,
        l: u32,
        i: f64,
        text: &str,
        store: &JsStore,
    ) -> Result<(), JsError> {
        let host = Host::new(store);
        self.memory
            .complete_in(NodeId::new(level(l)?, id(i)?), text, &host)
            .map_err(|e| JsError::new(&e.to_string()))?;
        host.check()
    }

    /// Work to do now, as JSON: `[{kind: "free", l, i, text} | {kind: "model", l, i}]`.
    /// A failed read stops the pump before it builds anything from it; the
    /// work found before it is returned (the free nodes are built in the core
    /// and must be stored), and with none it throws the read's error.
    pub fn pump(&mut self, store: &JsStore) -> Result<String, JsError> {
        let host = Host::new(store);
        let work = self.memory.pump(&host);
        if work.is_empty() {
            host.check()?;
        }
        let work: Vec<WorkJson> = work
            .into_iter()
            .map(|w| match w {
                Work::Free { node, text } => WorkJson::Free {
                    l: node.l,
                    i: node.i,
                    text,
                },
                Work::Model { node } => WorkJson::Model {
                    l: node.l,
                    i: node.i,
                },
            })
            .collect();
        Ok(serde_json::to_string(&work).unwrap_or_else(|_| "[]".into()))
    }

    pub fn complete(&mut self, l: u32, i: f64, text: &str) -> Result<(), JsError> {
        if self.memory.is_lazy() {
            return Err(JsError::new("a lazy memory completes with completeIn"));
        }
        self.memory
            .complete(NodeId::new(level(l)?, id(i)?), text)
            .map_err(|e| JsError::new(&e.to_string()))
    }

    pub fn fail(&mut self, l: u32, i: f64) -> Result<(), JsError> {
        self.memory.fail(NodeId::new(level(l)?, id(i)?));
        Ok(())
    }

    pub fn settled(&self) -> bool {
        self.memory.settled()
    }

    pub fn first(&self) -> f64 {
        self.memory.first() as f64
    }

    pub fn len(&self) -> f64 {
        self.memory.len() as f64
    }

    #[wasm_bindgen(js_name = isEmpty)]
    pub fn is_empty(&self) -> bool {
        self.memory.is_empty()
    }

    #[wasm_bindgen(js_name = viewSize)]
    pub fn view_size(&self) -> f64 {
        self.memory.view_size() as f64
    }

    /// The view parts as JSON `[{l, i, name}]`.
    pub fn view(&self) -> String {
        let parts: Vec<NodeJson> = self
            .memory
            .view()
            .iter()
            .map(|p| NodeJson {
                l: p.l,
                i: p.i,
                name: p.name(),
            })
            .collect();
        serde_json::to_string(&parts).unwrap_or_else(|_| "[]".into())
    }

    /// The turn input of spec 5a as JSON `{frozen: {parts: [[l, i]], front, unbuilt, cuts}, rerendered, view: [piece],
    /// delta: [block]}`: the frozen view cut into its 4-line blocks (`block_pieces`), then the delta
    /// blocks. `frozen` is the JSON this returned last turn, or "" for none; `new` is how many of the
    /// log's last messages are this turn's new ones (never shown in a re-rendered view).
    #[wasm_bindgen(js_name = turnInput)]
    pub fn turn_input(&self, store: &JsStore, frozen: &str, new: f64) -> Result<String, JsError> {
        #[derive(Serialize, serde::Deserialize)]
        struct FrozenJson {
            parts: Vec<(u32, u64)>,
            front: u64,
            #[serde(default)]
            unbuilt: Vec<(u32, u64)>,
            #[serde(default)]
            cuts: Vec<u64>,
            #[serde(default)]
            starts: Vec<u64>,
        }
        #[derive(Serialize)]
        struct Out<'a> {
            frozen: FrozenJson,
            rerendered: bool,
            view: Vec<&'a str>,
            delta: Vec<String>,
        }
        let prior = if frozen.is_empty() {
            None
        } else {
            let f: FrozenJson = serde_json::from_str(frozen)
                .map_err(|e| JsError::new(&format!("frozen view is not JSON: {e}")))?;
            for (l, _) in f.parts.iter().chain(f.unbuilt.iter()) {
                level(*l)?;
            }
            let ids = |v: &[(u32, u64)]| {
                v.iter()
                    .map(|(l, i)| core::NodeId::new(*l, *i))
                    .collect::<Vec<_>>()
            };
            // A stored view that does not end at its front (a reset log) is ignored: the core renders again.
            let parts = ids(&f.parts);
            if parts.last().map_or(0, |p| p.end()) != f.front {
                None
            } else {
                Some(core::Frozen {
                    parts,
                    front: f.front,
                    unbuilt: ids(&f.unbuilt),
                    cuts: f.cuts.clone(),
                    starts: f.starts.clone(),
                })
            }
        };
        let host = Host::new(store);
        let t = core::turn_input(&self.memory, &host, prior.as_ref(), new.max(0.0) as u64);
        host.check()?;
        let out = Out {
            frozen: FrozenJson {
                parts: t.frozen.parts.iter().map(|p| (p.l, p.i)).collect(),
                front: t.frozen.front,
                unbuilt: t.frozen.unbuilt.iter().map(|p| (p.l, p.i)).collect(),
                cuts: t.frozen.cuts.clone(),
                starts: t.frozen.starts.clone(),
            },
            rerendered: t.rerendered,
            view: core::block_pieces(&t.view),
            delta: t.delta.clone(),
        };
        Ok(serde_json::to_string(&out).unwrap_or_default())
    }

    /// The rendered view as JSON `{text, marks}` (marks are indices into the JS string `text`, UTF-16 code units).
    #[wasm_bindgen(js_name = renderView)]
    pub fn render_view(&self, store: &JsStore) -> Result<String, JsError> {
        #[derive(Serialize)]
        struct Out {
            text: String,
            marks: Vec<usize>,
        }
        let host = Host::new(store);
        let v = core::render_view(&self.memory, &host);
        host.check()?;
        Ok(serde_json::to_string(&Out {
            marks: js_offsets(&v.text, &v.marks),
            text: v.text,
        })
        .unwrap_or_default())
    }

    /// `zoom(id, n)`; throws "No line id+n." when refused.
    pub fn zoom(&self, store: &JsStore, id: f64, n: f64) -> Result<String, JsError> {
        // A non-integer or negative address names no line (section 7.1).
        let (Ok(i), Ok(count)) = (self::id(id), self::id(n)) else {
            return Err(JsError::new(&format!("No line {id}+{n}.")));
        };
        let host = Host::new(store);
        let out =
            core::zoom(&self.memory, &host, i, count).map_err(|e| JsError::new(&e.to_string()))?;
        host.check()?;
        Ok(out)
    }

    /// A memory tool with no effect outside the memory (chief-kernel
    /// `call_pure`; section 13, export 2): `zoom` or `date`, its arguments
    /// as JSON, and `ctx_json` (`{utc_offset_minutes}`). `date` reads the
    /// store's `date(i)`. Any other tool throws: the host runs it.
    #[wasm_bindgen(js_name = callPure)]
    pub fn call_pure(
        &self,
        store: &JsStore,
        name: &str,
        args_json: &str,
        ctx_json: &str,
    ) -> Result<String, JsError> {
        let host = Host::new(store);
        let dates = |id: u64| match store.date_of(id as f64) {
            Ok(d) => d,
            Err(e) => {
                host.fail(format!("store.date({id}) failed: {}", describe(&e)));
                None
            }
        };
        let out = chief_kernel::call_pure(name, args_json, ctx_json, &self.memory, &host, &dates)
            .map_err(|e| JsError::new(&e))?;
        host.check()?;
        Ok(out)
    }

    /// The compactor call for node (l, i) as JSON `{system, context, marks,
    /// step, cut, room}`: `marks` are JS string indices (UTF-16 code units) into the context
    /// where a cached piece ends (section 8); send each piece as its own
    /// block with a breakpoint. `cut` is null, or the prefix a too-long
    /// message's line starts with: run the size loop with `sizeCheck(tries,
    /// room)` and store `finishLine(cut, line)`, which adds it.
    /// `prompt` is `taelin`, `cmux` or `custom` (then `custom` is its text).
    ///
    /// When a read fails, the call throws and the node is released (as if
    /// `fail(l, i)` were called): `pump` marked it busy, and a host that only
    /// retries `compactRequest` would otherwise leave it busy forever, which
    /// under rule 3 blocks every later level-0 node and every turn. The host
    /// waits its fixed retry delay and pumps again.
    #[wasm_bindgen(js_name = compactRequest)]
    pub fn compact_request(
        &mut self,
        store: &JsStore,
        l: u32,
        i: f64,
        prompt: &str,
        custom: &str,
        agent: &str,
    ) -> Result<String, JsError> {
        #[derive(Serialize)]
        struct Out {
            system: String,
            context: String,
            marks: Vec<usize>,
            step: String,
            cut: Option<String>,
            room: usize,
        }
        let choice = match prompt {
            "cmux" => CompactPrompt::Cmux,
            "custom" => CompactPrompt::Custom(custom.to_string()),
            _ => CompactPrompt::Taelin,
        };
        let node = NodeId::new(level(l)?, id(i)?);
        let host = Host::new(store);
        let r = core::compact_request(&self.memory, &host, node, choice.text(agent));
        if let Err(e) = host.check() {
            self.memory.fail(node);
            return Err(e);
        }
        let r = match r {
            Ok(r) => r,
            Err(missing) => {
                self.memory.fail(node);
                return Err(JsError::new(&missing.to_string()));
            }
        };
        let marks = js_offsets(&r.context, &core::cache_marks(&r.context));
        let room = r.room();
        Ok(serde_json::to_string(&Out {
            system: r.system,
            context: r.context,
            marks,
            step: r.step,
            cut: r.cut,
            room,
        })
        .unwrap_or_default())
    }
}

/// The size loop (section 4.3) on the replies so far (JSON array of strings):
/// JSON `{accept: string} | {retry: string} | {fail: true}`. `room` is the
/// request's `room` (default NODE).
#[wasm_bindgen(js_name = sizeCheck)]
pub fn size_check(tries_json: &str, room: Option<u32>) -> Result<String, JsError> {
    let tries: Vec<String> = serde_json::from_str(tries_json)?;
    let limit = room.map_or(core::NODE, |r| r as usize);
    let out = match core::size_check_in(&tries, limit) {
        core::SizeCheck::Accept(text) => serde_json::json!({ "accept": text }),
        core::SizeCheck::Retry(text) => serde_json::json!({ "retry": text }),
        core::SizeCheck::Fail => serde_json::json!({ "fail": true }),
    };
    Ok(out.to_string())
}

/// The node text for an accepted reply of a request whose `cut` is set: the
/// cut prefix first (once, even when the model already wrote it).
#[wasm_bindgen(js_name = finishLine)]
pub fn finish_line(cut: &str, line: &str) -> String {
    if line.starts_with(cut) {
        line.to_string()
    } else {
        format!("{cut}{line}")
    }
}

/// The checkpoint's JSON (the same form as optchat-host's `memory/checkpoint`).
fn encode_checkpoint(c: &Checkpoint) -> String {
    let parts = |v: &[NodeId]| {
        v.iter()
            .map(|p| serde_json::json!([p.l, p.i]))
            .collect::<Vec<serde_json::Value>>()
    };
    serde_json::json!({
        "t": c.t,
        "low": c.low,
        "view": parts(&c.view),
        "compact_view": parts(&c.compact_view),
        "merging": c.merging,
        "compact_merging": c.compact_merging,
    })
    .to_string()
}

fn decode_checkpoint(text: &str) -> Option<Checkpoint> {
    let v: serde_json::Value = serde_json::from_str(text).ok()?;
    let low = v["low"]
        .as_array()?
        .iter()
        .map(serde_json::Value::as_u64)
        .collect::<Option<Vec<u64>>>()?;
    let parts = |v: &serde_json::Value| {
        v.as_array()?
            .iter()
            .map(|p| {
                let l = p.get(0)?.as_u64()?;
                let i = p.get(1)?.as_u64()?;
                (l < 64).then(|| NodeId::new(l as u32, i))
            })
            .collect::<Option<Vec<NodeId>>>()
    };
    Some(Checkpoint {
        t: v["t"].as_u64()?,
        low,
        view: parts(&v["view"])?,
        compact_view: match v.get("compact_view") {
            Some(c) => parts(c)?,
            None => Vec::new(),
        },
        merging: v["merging"].as_bool().unwrap_or(false),
        compact_merging: v["compact_merging"].as_bool().unwrap_or(false),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Audit major 2 (fixed by 8c5aecd3f8a2, ids, and c6f2207069d6, zoom's
    /// checked end): a JS number names a message only when it is a finite,
    /// non-negative integer within 2^53, and a level is below 64.
    #[test]
    fn only_whole_non_negative_numbers_within_2_pow_53_are_ids() {
        for bad in [f64::NAN, f64::INFINITY, -1.0, 0.5, 9_007_199_254_740_992.0] {
            assert!(check_id(bad).is_err(), "{bad} was taken as an id");
        }
        assert_eq!(
            check_id(9_007_199_254_740_991.0).ok(),
            Some(9_007_199_254_740_991)
        );
        assert!(check_level(64).is_err());
        assert_eq!(check_level(63).ok(), Some(63));
    }

    /// Audit major 4: the marks a JS caller gets index its string (UTF-16
    /// code units), not the UTF-8 bytes the core cuts at: `text.slice(0, m)`
    /// must end exactly at the line end the core chose.
    #[test]
    fn marks_given_to_javascript_are_utf16_indices() {
        let text = "é😀\nb\n";
        // The core's byte mark after the first line: 2 + 4 + 1 bytes.
        assert_eq!(js_offsets(text, &[7, 9]), vec![4, 6]);
        let ascii = "ab\ncd\n";
        assert_eq!(js_offsets(ascii, &[3]), vec![3]);
    }
}

/// The system text of a Chief turn, exactly as the Mac host renders it
/// (chief-kernel `render_system`; cloud-chief-durable-DESIGN.md section 13,
/// export 1). `profile_json`: `{person?, instructions?, channels?, record?}`;
/// `engine`: `claude`, `codex`, `pi-durable`, ...; `tools_json`: `{mode?,
/// chief?, profile_tool?, chiefs_tool?}`. Throws on bad JSON, an unknown
/// engine, or a cli engine without its launcher path.
#[wasm_bindgen(js_name = renderSystem)]
pub fn render_system(
    profile_json: &str,
    engine: &str,
    tools_json: &str,
) -> Result<String, JsError> {
    chief_kernel::render_system(profile_json, engine, tools_json).map_err(|e| JsError::new(&e))
}

/// The Chief's tool specs for `engine` (`pi-durable`, ...) and a grant
/// (`{tools?: [names]}`), as JSON `[{name, description, json_schema, replay:
/// "safe" | "once"}]` (chief-kernel `tools::specs`; section 13, export 2).
#[wasm_bindgen(js_name = toolSpecs)]
pub fn tool_specs(engine: &str, grant_json: &str) -> Result<String, JsError> {
    chief_kernel::tools::specs(engine, grant_json)
        .map(|v| v.to_string())
        .map_err(|e| JsError::new(&e))
}

/// The reply and outcome ledgers as a pure fold (chief-kernel
/// `ledger::ledger_apply`; section 13, export 3): applies one event to the
/// state at `ctx_json.now_ms` and answers `{state, intents}` as JSON. The
/// host stores the state and performs each intent (`schedule`, `notice`,
/// `post`) with its key, in one transaction with its own rows.
#[wasm_bindgen(js_name = ledgerApply)]
pub fn ledger_apply(state_json: &str, event_json: &str, ctx_json: &str) -> Result<String, JsError> {
    chief_kernel::ledger::ledger_apply(state_json, event_json, ctx_json)
        .map_err(|e| JsError::new(&e))
}
