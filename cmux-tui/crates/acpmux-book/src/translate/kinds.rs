//! Every v1 kind the hub writes, and what the chat draws of it: one line a kind (decision 231).
//! A `Row` is drawn from its line alone; `Code` is drawn or read by code that keeps state
//! (the line names where); `Not` is not drawn, with the reason. A kind in none of the tables is
//! counted (`Counters::unknown_kinds`). Both tables are sorted by name; a test holds that.
use crate::row::RowKind;

/// How a copied field is checked. A value of another type is not copied; a string past its cap
/// is cut at a character and counted (`Counters::cut_fields`). An empty string is absent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Ty {
    Str(usize),
    /// Copied only when it is `true`; `false` is absent.
    True,
    Num,
}
#[derive(Clone, Copy, Debug)]
pub(super) struct Field {
    /// The key in the v1 record's `msg`.
    pub from: &'static str,
    /// The `AcpmuxRow` field it feeds.
    pub to: &'static str,
    pub ty: Ty,
}
#[derive(Clone, Copy, Debug)]
#[cfg_attr(not(test), allow(dead_code, reason = "the table's own words, read by its tests"))]
pub(super) struct Drawn {
    pub kind: RowKind,
    /// The row's `notice`, for a notice row.
    pub notice: &'static str,
    pub fields: &'static [Field],
    /// The row's text: the first of these `msg` keys that is present, into the body's `content`.
    pub text: &'static [&'static str],
    /// The later kind that patches this row, and the key both carry; none yet.
    pub patch: Option<(&'static str, &'static str)>,
}
#[derive(Clone, Copy, Debug)]
#[cfg_attr(not(test), allow(dead_code, reason = "the table's own words, read by its tests"))]
pub(super) enum Draw {
    Row(Drawn),
    Code(&'static str),
    Not(&'static str),
}
#[derive(Clone, Copy, Debug)]
pub(super) struct Kind {
    pub name: &'static str,
    pub draw: Draw,
}

const fn notice(name: &'static str, fields: &'static [Field]) -> Kind {
    Kind {
        name,
        draw: Draw::Row(Drawn {
            kind: RowKind::Notice,
            notice: name,
            fields,
            text: NOTICE_TEXT,
            patch: None,
        }),
    }
}
const fn code(name: &'static str, by: &'static str) -> Kind {
    Kind { name, draw: Draw::Code(by) }
}
const fn not(name: &'static str, why: &'static str) -> Kind {
    Kind { name, draw: Draw::Not(why) }
}
const fn f(from: &'static str, to: &'static str, ty: Ty) -> Field {
    Field { from, to, ty }
}

const NOTICE_TEXT: &[&str] = &["text", "error", "reason", "detail"];
/// The turn-end notice's fields copied as they are. `tokens`, `checkpoint`, `error`, `seq`,
/// `continued` and `retry` are computed from the same record (`State::turn_end`).
pub(super) const TURN_END: &[Field] = &[
    f("status", "status", Ty::Str(64)),
    f("errorCode", "errorCode", Ty::Str(64)),
    f("cancelForced", "stopForced", Ty::True),
];

const ASK: &str = "PR 2: an ask row, which its decision patches";
const USER: &str = "PR 2: what a user row says of its sender";
const RECORD: &str = "PR 3: a record row";
const LIVE: &str = "PR 4: the open group row's live state";
const QUEUE: &str = "row 2d: the queue head's entry, not a row";
const RESULT: &str = "turn_result, which follows it, ends the turn";
const SUMMARY: &str = "read over the v1 connection (the summary or page state), not a row";
const UNREAD: &str = "the chat view reads nothing of it";

pub(super) const MUX: &[Kind] = &[
    not("_acpmux/message", USER),
    not("adopted", UNREAD),
    not("agent_hold", UNREAD),
    not("agent_pair_dropped", RECORD),
    not("agent_pair_held", RECORD),
    not("agent_pair_paused", RECORD),
    not("agent_pair_released", RECORD),
    not("agent_pair_resumed", RECORD),
    not("agent_start_retried_at_normal", UNREAD),
    not("agent_start_retrying", UNREAD),
    not("agent_start_stopped", UNREAD),
    not("agent_start_timed_out", UNREAD),
    not("agent_start_waiting", UNREAD),
    not("asks_before_tools_claim", UNREAD),
    not("auto_resume_exhausted", UNREAD),
    not("auto_resume_manual", UNREAD),
    not("auto_resume_restored", UNREAD),
    not("auto_resume_scheduled", UNREAD),
    not("auto_resume_settled", UNREAD),
    not("auto_resume_skipped", UNREAD),
    not("auto_resume_stopped", UNREAD),
    not("background_turn", RECORD),
    not("background_wait_ended", UNREAD),
    not("bookmarks", SUMMARY),
    not("bridge_delivered", UNREAD),
    not("claim_checks", "a reply's claims, which the chat view does not draw"),
    not("coach", RECORD),
    not("coach_offer", RECORD),
    not("composer", UNREAD),
    not("config", UNREAD),
    not("created", UNREAD),
    code("dequeued", "the queue: the entry leaves (State::queue_remove)"),
    not("directories", UNREAD),
    not("elevation_decision", ASK),
    not("elevation_request", ASK),
    notice("exited", &[]),
    notice("failover", &[]),
    not("failover_skipped", UNREAD),
    not("fork_child", UNREAD),
    notice("fork_start_failed", &[]),
    notice("forked", &[]),
    not("full_access_end_failed", UNREAD),
    not("full_access_ended", UNREAD),
    not("full_access_refused", UNREAD),
    not("git", UNREAD),
    not("github_broker_action", UNREAD),
    not("grant_cleared", UNREAD),
    not("harness_sandbox_failed", UNREAD),
    not("harness_sandbox_recovered", UNREAD),
    not("host_adopted", UNREAD),
    not("host_ended", LIVE),
    notice("host_notice", &[]),
    not("host_reattached", UNREAD),
    not("host_started", LIVE),
    not("host_unadoptable", UNREAD),
    not("host_unanswered", UNREAD),
    not("host_unreachable_ended", UNREAD),
    not("imported", UNREAD),
    not("inbox", UNREAD),
    not("inbox_answered", UNREAD),
    not("inbox_noticed", UNREAD),
    not("inbox_read", UNREAD),
    not("inbox_removed", UNREAD),
    not("inbox_returned", UNREAD),
    not("listing_ended", UNREAD),
    not("loop_cleared", UNREAD),
    not("loop_detected", UNREAD),
    not("mcp_connect_decision", UNREAD),
    not("mcp_connect_request", UNREAD),
    not("mcp_connect_result", UNREAD),
    not("memory_offer", RECORD),
    not("memory_resolved", RECORD),
    code("message_superseded", "hides the superseded reply (State::supersede)"),
    not("mode", UNREAD),
    not("model", UNREAD),
    not("native_history", SUMMARY),
    not("permission_auto", ASK),
    not("permission_chat_allowance", ASK),
    not("permission_decision", ASK),
    not("permission_group", ASK),
    not("permission_reissued", ASK),
    not("permission_request", ASK),
    not("permission_withdrawn", ASK),
    not("plan_build", RECORD),
    not("policy", UNREAD),
    not("policy_refused", UNREAD),
    notice("policy_unenforced", &[]),
    not("pool_taken", UNREAD),
    not("preset_approval_decision", RECORD),
    not("preset_approval_request", RECORD),
    not("preset_mode_dropped", UNREAD),
    not("process_update", UNREAD),
    not(
        "prompt_refused",
        "said live only, over the v1 connection: a loaded history does not repeat it",
    ),
    not("prompt_retracted", UNREAD),
    not("prompt_stop_requested", UNREAD),
    not("queue_approved", QUEUE),
    code("queue_declined", "the queue: the entry leaves (State::queue_remove)"),
    code("queue_order", "the queue's order, and a prompt sent now (State::queue_order)"),
    code("queue_paused", "the queue: entries held (State::queue_set_held)"),
    code("queue_removed", "the queue: the entry leaves (State::queue_remove)"),
    not("queue_restored", UNREAD),
    code("queue_resumed", "the queue: entries released (State::queue_set_held)"),
    not("queue_updated", QUEUE),
    code("queued", "the queue: an entry (State::queue_add)"),
    not("race", SUMMARY),
    notice("recap", &[]),
    not("registered", UNREAD),
    not("remote_control_ended", UNREAD),
    not("remote_control_restored", UNREAD),
    not("remote_floor_cancel", UNREAD),
    not("remote_sandbox", UNREAD),
    code("removed", "an older writer's withdrawal: the queue entry and its row leave"),
    not("renamed", UNREAD),
    not("reopened", LIVE),
    not("respawn_pending", UNREAD),
    not("resume_failed", UNREAD),
    not("resumed", LIVE),
    code("retracted", "an older writer's withdrawal: the queue entry and its row leave"),
    not("route_changed", UNREAD),
    not("route_probe", UNREAD),
    not("rules", UNREAD),
    not("secret_decision", ASK),
    not("secret_request", ASK),
    not("secret_run", UNREAD),
    not("sender_claim", USER),
    not("session_offer", RECORD),
    not("session_offer_decision", RECORD),
    not("start_default_skipped", UNREAD),
    not("status", SUMMARY),
    not("stderr", UNREAD),
    code("steer_read", "a steer read: its user row settles (State::steer_read)"),
    not("steer_returned", UNREAD),
    not("steer_withdrawn", USER),
    not("stop_escalated", UNREAD),
    not("stop_restarted", UNREAD),
    notice("stopped", &[]),
    not("stopped_while_starting", UNREAD),
    notice("stopping", &[]),
    not("subagent_retry", LIVE),
    not("subagents_running", UNREAD),
    not("subagents_working", UNREAD),
    not("subsession", RECORD),
    not("subsessions_waiting", UNREAD),
    not("tags", UNREAD),
    not("team_message_consumed", UNREAD),
    not("team_message_read", UNREAD),
    not("titled", UNREAD),
    not("tools", UNREAD),
    not("transfer_aborted", UNREAD),
    not("transfer_guarded", UNREAD),
    not("transfer_out", UNREAD),
    not("transferred", UNREAD),
    not("transferred_in", UNREAD),
    not("turn_control", UNREAD),
    not("turn_end", RESULT),
    not("turn_error", RESULT),
    not("turn_heard", LIVE),
    Kind {
        name: "turn_result",
        draw: Draw::Row(Drawn {
            kind: RowKind::Notice,
            notice: "turn_result",
            fields: TURN_END,
            text: &[],
            patch: None,
        }),
    },
    not("turn_retrying", LIVE),
    not("turn_silent", LIVE),
    code("turn_started", "names the running turn (State::turn_key)"),
    not("turn_stop_requested", UNREAD),
    not("unstuck", UNREAD),
    not("usage_stats", UNREAD),
    code("user_message", "a user row, and a new turn's group row (State::prompt)"),
    not("watch_started", UNREAD),
    not("watch_taken_over", UNREAD),
    not("worktree_recreate_failed", UNREAD),
    not("worktree_recreated", UNREAD),
    not("worktree_restore_failed", UNREAD),
    not("worktree_restored", UNREAD),
];

/// An agent's `session/update`, by its `sessionUpdate`.
pub(super) const UPDATES: &[Kind] = &[
    code("agent_message_chunk", "a text row (State::text)"),
    code("agent_thought_chunk", "a thinking row (State::text)"),
    not("available_commands_update", SUMMARY),
    not("background_task_update", RECORD),
    code("compaction", "a compaction notice, open while it runs"),
    not("config_option_update", SUMMARY),
    not("current_mode_update", SUMMARY),
    code("plan", "the turn's plan row (State::plan)"),
    not("prompt_suggestion", LIVE),
    not("session_info_update", SUMMARY),
    code("subagent_progress", "a sub row (State::sub)"),
    not("subagent_state_update", LIVE),
    code("tool_call", "a tool row (State::tool)"),
    code("tool_call_update", "a tool row (State::tool)"),
    not("usage_update", LIVE),
    not("user_message_chunk", "the prompt is the mux user_message's row"),
];

/// Every other `in` and `out` record: requests, responses and the harness's own lines.
#[cfg_attr(not(test), allow(dead_code, reason = "the table's own words, read by its tests"))]
pub(super) const PROTOCOL: &str =
    "protocol traffic: what the chat draws of it comes as mux records and updates";

pub(super) fn find(table: &'static [Kind], name: &str) -> Option<&'static Kind> {
    table.binary_search_by(|kind| kind.name.cmp(name)).ok().and_then(|at| table.get(at))
}
