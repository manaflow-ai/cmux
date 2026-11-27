/* tslint:disable */
/* eslint-disable */

/**
 * One agent's memory state in the MemoryDO.
 */
export class OptChat {
    free(): void;
    [Symbol.dispose](): void;
    /**
     * `append` for any memory: sizes it does not hold come from `store`.
     */
    appendIn(store: any): number;
    /**
     * Appends one message (already stored) and returns its id. Not for a lazy memory (`appendIn`).
     */
    append(): number;
    /**
     * A memory tool with no effect outside the memory (chief-kernel
     * `call_pure`; section 13, export 2): `zoom` or `date`, its arguments
     * as JSON, and `ctx_json` (`{utc_offset_minutes}`). `date` reads the
     * store's `date(i)`. Any other tool throws: the host runs it.
     */
    callPure(store: any, name: string, args_json: string, ctx_json: string): string;
    /**
     * Where the memory stands, as JSON for `resume`: `{t, low, view, compact_view, merging, compact_merging}`.
     */
    checkpoint(): string;
    /**
     * The compactor call for node (l, i) as JSON `{system, context, marks,
     * step, cut, room}`: `marks` are JS string indices (UTF-16 code units) into the context
     * where a cached piece ends (section 8); send each piece as its own
     * block with a breakpoint. `cut` is null, or the prefix a too-long
     * message's line starts with: run the size loop with `sizeCheck(tries,
     * room)` and store `finishLine(cut, line)`, which adds it.
     * `prompt` is `taelin`, `cmux` or `custom` (then `custom` is its text).
     *
     * When a read fails, the call throws and the node is released (as if
     * `fail(l, i)` were called): `pump` marked it busy, and a host that only
     * retries `compactRequest` would otherwise leave it busy forever, which
     * under rule 3 blocks every later level-0 node and every turn. The host
     * waits its fixed retry delay and pumps again.
     */
    compactRequest(store: any, l: number, i: number, prompt: string, custom: string, agent: string): string;
    /**
     * `complete` for any memory: sizes it does not hold come from `store`.
     */
    completeIn(l: number, i: number, text: string, store: any): void;
    complete(l: number, i: number, text: string): void;
    fail(l: number, i: number): void;
    first(): number;
    isEmpty(): boolean;
    isLazy(): boolean;
    len(): number;
    /**
     * Rebuilds after a restart: `t` messages and the built nodes as JSON
     * `[[l, i, bytes], ...]`.
     */
    static load(t: number, built_json: string, budget: number): OptChat;
    /**
     * Drops the sizes of nodes outside the views (read from the store when needed); from here on
     * change it with `appendIn` and `completeIn`.
     */
    makeLazy(): void;
    /**
     * A new, empty memory with a view budget in bytes (`VIEW` when 0).
     */
    constructor(budget: number);
    /**
     * Work to do now, as JSON: `[{kind: "free", l, i, text} | {kind: "model", l, i}]`.
     * A failed read stops the pump before it builds anything from it; the
     * work found before it is returned (the free nodes are built in the core
     * and must be stored), and with none it throws the read's error.
     */
    pump(store: any): string;
    /**
     * The rendered view as JSON `{text, marks}` (marks are indices into the JS string `text`, UTF-16 code units).
     */
    renderView(store: any): string;
    /**
     * Picks up from `checkpoint()`'s JSON without reading the whole log (spec 3.2: the saved view is
     * loaded, never rebuilt): `t` messages, and the frontier as JSON `[[l, i, bytes], ...]` (every stored
     * node at or above the checkpoint's `low` of its level). Messages after the checkpoint are appended
     * as live. The result is lazy: change it with `appendIn` and `completeIn`. Undefined when the
     * checkpoint does not fit the store (the host then folds with `load` + `makeLazy`).
     */
    static resume(checkpoint: string, t: number, frontier_json: string, budget: number, store: any): OptChat | undefined;
    settled(): boolean;
    /**
     * The turn input of spec 5a as JSON `{frozen: {parts: [[l, i]], front, unbuilt, cuts}, rerendered, view: [piece],
     * delta: [block]}`: the frozen view cut into its 4-line blocks (`block_pieces`), then the delta
     * blocks. `frozen` is the JSON this returned last turn, or "" for none; `new` is how many of the
     * log's last messages are this turn's new ones (never shown in a re-rendered view).
     */
    turnInput(store: any, frozen: string, _new: number): string;
    viewSize(): number;
    /**
     * The view parts as JSON `[{l, i, name}]`.
     */
    view(): string;
    /**
     * `zoom(id, n)`; throws "No line id+n." when refused.
     */
    zoom(store: any, id: number, n: number): string;
}

/**
 * The node text for an accepted reply of a request whose `cut` is set: the
 * cut prefix first (once, even when the model already wrote it).
 */
export function finishLine(cut: string, line: string): string;

/**
 * The reply and outcome ledgers as a pure fold (chief-kernel
 * `ledger::ledger_apply`; section 13, export 3): applies one event to the
 * state at `ctx_json.now_ms` and answers `{state, intents}` as JSON. The
 * host stores the state and performs each intent (`schedule`, `notice`,
 * `post`) with its key, in one transaction with its own rows.
 */
export function ledgerApply(state_json: string, event_json: string, ctx_json: string): string;

/**
 * The system text of a Chief turn, exactly as the Mac host renders it
 * (chief-kernel `render_system`; cloud-chief-durable-DESIGN.md section 13,
 * export 1). `profile_json`: `{person?, instructions?, channels?, record?}`;
 * `engine`: `claude`, `codex`, `pi-durable`, ...; `tools_json`: `{mode?,
 * chief?, profile_tool?, chiefs_tool?}`. Throws on bad JSON, an unknown
 * engine, or a cli engine without its launcher path.
 */
export function renderSystem(profile_json: string, engine: string, tools_json: string): string;

/**
 * The size loop (section 4.3) on the replies so far (JSON array of strings):
 * JSON `{accept: string} | {retry: string} | {fail: true}`. `room` is the
 * request's `room` (default NODE).
 */
export function sizeCheck(tries_json: string, room?: number | null): string;

/**
 * The Chief's tool specs for `engine` (`pi-durable`, ...) and a grant
 * (`{tools?: [names]}`), as JSON `[{name, description, json_schema, replay:
 * "safe" | "once"}]` (chief-kernel `tools::specs`; section 13, export 2).
 */
export function toolSpecs(engine: string, grant_json: string): string;

export type InitInput = RequestInfo | URL | Response | BufferSource | WebAssembly.Module;

export interface InitOutput {
    readonly memory: WebAssembly.Memory;
    readonly __wbg_optchat_free: (a: number, b: number) => void;
    readonly finishLine: (a: number, b: number, c: number, d: number) => [number, number];
    readonly ledgerApply: (a: number, b: number, c: number, d: number, e: number, f: number) => [number, number, number, number];
    readonly optchat_append: (a: number) => [number, number, number];
    readonly optchat_appendIn: (a: number, b: any) => [number, number, number];
    readonly optchat_callPure: (a: number, b: any, c: number, d: number, e: number, f: number, g: number, h: number) => [number, number, number, number];
    readonly optchat_checkpoint: (a: number) => [number, number];
    readonly optchat_compactRequest: (a: number, b: any, c: number, d: number, e: number, f: number, g: number, h: number, i: number, j: number) => [number, number, number, number];
    readonly optchat_complete: (a: number, b: number, c: number, d: number, e: number) => [number, number];
    readonly optchat_completeIn: (a: number, b: number, c: number, d: number, e: number, f: any) => [number, number];
    readonly optchat_fail: (a: number, b: number, c: number) => [number, number];
    readonly optchat_first: (a: number) => number;
    readonly optchat_isEmpty: (a: number) => number;
    readonly optchat_isLazy: (a: number) => number;
    readonly optchat_len: (a: number) => number;
    readonly optchat_load: (a: number, b: number, c: number, d: number) => [number, number, number];
    readonly optchat_makeLazy: (a: number) => void;
    readonly optchat_new: (a: number) => number;
    readonly optchat_pump: (a: number, b: any) => [number, number, number, number];
    readonly optchat_renderView: (a: number, b: any) => [number, number, number, number];
    readonly optchat_resume: (a: number, b: number, c: number, d: number, e: number, f: number, g: any) => [number, number, number];
    readonly optchat_settled: (a: number) => number;
    readonly optchat_turnInput: (a: number, b: any, c: number, d: number, e: number) => [number, number, number, number];
    readonly optchat_view: (a: number) => [number, number];
    readonly optchat_viewSize: (a: number) => number;
    readonly optchat_zoom: (a: number, b: any, c: number, d: number) => [number, number, number, number];
    readonly renderSystem: (a: number, b: number, c: number, d: number, e: number, f: number) => [number, number, number, number];
    readonly sizeCheck: (a: number, b: number, c: number) => [number, number, number, number];
    readonly toolSpecs: (a: number, b: number, c: number, d: number) => [number, number, number, number];
    readonly __wbindgen_malloc: (a: number, b: number) => number;
    readonly __wbindgen_realloc: (a: number, b: number, c: number, d: number) => number;
    readonly __wbindgen_exn_store: (a: number) => void;
    readonly __externref_table_alloc: () => number;
    readonly __wbindgen_externrefs: WebAssembly.Table;
    readonly __wbindgen_free: (a: number, b: number, c: number) => void;
    readonly __externref_table_dealloc: (a: number) => void;
    readonly __wbindgen_start: () => void;
}

export type SyncInitInput = BufferSource | WebAssembly.Module;

/**
 * Instantiates the given `module`, which can either be bytes or
 * a precompiled `WebAssembly.Module`.
 *
 * @param {{ module: SyncInitInput }} module - Passing `SyncInitInput` directly is deprecated.
 *
 * @returns {InitOutput}
 */
export function initSync(module: { module: SyncInitInput } | SyncInitInput): InitOutput;

/**
 * If `module_or_path` is {RequestInfo} or {URL}, makes a request and
 * for everything else, calls `WebAssembly.instantiate` directly.
 *
 * @param {{ module_or_path: InitInput | Promise<InitInput> }} module_or_path - Passing `InitInput` directly is deprecated.
 *
 * @returns {Promise<InitOutput>}
 */
export default function __wbg_init (module_or_path?: { module_or_path: InitInput | Promise<InitInput> } | InitInput | Promise<InitInput>): Promise<InitOutput>;
