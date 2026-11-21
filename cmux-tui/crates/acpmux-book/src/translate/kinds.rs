//! Every v1 kind the hub writes, and what the chat draws of it: one line a kind (decision 231).
//! A `Row` is drawn from its line alone; `Code` is drawn or read by code that keeps state
//! (the line names where); `Not` is not drawn, with the reason; `PageState` is not drawn because
//! the page reads its whole state over a v1 attach (decision 234). A kind in none of the tables is
//! counted (`Counters::unknown_kinds`). Both tables are sorted by name; a test holds that.
use crate::row::RowKind;

/// How a copied field is checked. A value of another type is not copied; a string past its cap
/// is cut at a character and counted (`Counters::cut_fields`). An empty string is absent.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum Ty {
    Str(usize),
    /// Copied only when it is `true`; `false` is absent.
    True,
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
    /// The later kinds that patch this row, each with the key both carry.
    pub patch: &'static [(&'static str, &'static str)],
}
#[derive(Clone, Copy, Debug)]
#[cfg_attr(not(test), allow(dead_code, reason = "the table's own words, read by its tests"))]
pub(super) enum Draw {
    Row(Drawn),
    Code(&'static str),
    Not(&'static str),
    /// Not drawn: page state. Every record of the kind carries its whole state, which the page
    /// reads over a v1 attach that carries no rows (decision 234). Never also a row or a part.
    PageState,
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
            patch: &[],
        }),
    }
}
/// A card (decision 253): the record that opens it, the view's row kind it stands for, and the
/// later kinds that patch it by a key both carry. The fold is code (`cards.rs`).
const fn card(
    name: &'static str,
    card: &'static str,
    patch: &'static [(&'static str, &'static str)],
) -> Kind {
    Kind {
        name,
        draw: Draw::Row(Drawn { kind: RowKind::Card, notice: card, fields: &[], text: &[], patch }),
    }
}
const fn code(name: &'static str, by: &'static str) -> Kind {
    Kind { name, draw: Draw::Code(by) }
}
const fn page(name: &'static str) -> Kind {
    Kind { name, draw: Draw::PageState }
}
const fn not(name: &'static str, why: &'static str) -> Kind {
    Kind { name, draw: Draw::Not(why) }
}
const fn f(from: &'static str, to: &'static str, ty: Ty) -> Field {
    Field { from, to, ty }
}

const NOTICE_TEXT: &[&str] = &["text", "error", "reason", "detail"];
/// The turn-end notice's fields copied as they are. `tokens`, `checkpoint`, `error`, `seq` and
/// `retry` are computed from the same record (v1.rs `turn_result`), and `continued` from the
/// queue's records before it (`State::end_turn`).
pub(super) const TURN_END: &[Field] = &[
    f("status", "status", Ty::Str(64)),
    f("errorCode", "errorCode", Ty::Str(64)),
    f("cancelForced", "stopForced", Ty::True),
];

/// A record that patches a card, or a decision for one no longer held (a notice row of its own).
const PATCHES: &str = "patches its card by key (cards.rs); for a card not held, a notice row";
const TOOL_BG: &str = "PR 4: the tool row's background state, or a row when the call is not drawn";
const LIVE: &str = "PR 4: the open group row's live state";
const QUEUE: &str = "row 2d: the queue head's entry, not a row";
const RESULT: &str = "turn_result, which follows it, ends the turn";
const IMPORTED: &str = "marks where an imported history ends, read over the v1 connection";
const UNREAD: &str = "the chat view reads nothing of it";

pub(super) const MUX: &[Kind] = &[
    not(
        "_acpmux/message",
        "a message this chat sent another: that chat draws it from its own user_message",
    ),
    not("adopted", UNREAD),
    not("agent_hold", UNREAD),
    code("agent_pair_dropped", PATCHES),
    code("agent_pair_held", PATCHES),
    card(
        "agent_pair_paused",
        "agentPair",
        &[
            ("agent_pair_held", "from"),
            ("agent_pair_released", "peer"),
            ("agent_pair_dropped", "peer"),
            ("agent_pair_resumed", "peer"),
        ],
    ),
    code("agent_pair_released", PATCHES),
    code("agent_pair_resumed", PATCHES),
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
    not("background_turn", LIVE),
    not("background_wait_ended", UNREAD),
    page("bookmarks"),
    not("bridge_delivered", UNREAD),
    not("claim_checks", "a reply's claims, which the chat view does not draw"),
    code("coach", PATCHES),
    card("coach_offer", "promptCoach", &[("coach", "coachId")]),
    not("composer", UNREAD),
    not("config", UNREAD),
    not("created", UNREAD),
    code("dequeued", "the queue: the entry leaves (State::queue_remove)"),
    not("directories", UNREAD),
    code("elevation_decision", "settles its ask row with its outcome (State::decide_secret)"),
    code("elevation_request", "an ask row for the OK to run as root (State::ask_secret)"),
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
    card("memory_offer", "memoryOffer", &[("memory_resolved", "offerId")]),
    code("memory_resolved", PATCHES),
    code("message_superseded", "hides the superseded reply (State::supersede)"),
    not("mode", UNREAD),
    not("model", UNREAD),
    not("native_history", IMPORTED),
    code("permission_auto", "settles the ask the person was shown, if any (State::decide_auto)"),
    not("permission_chat_allowance", "the chat's allowance: the page reads its permission groups"),
    code("permission_decision", "settles its ask row (State::decide_permission)"),
    not("permission_group", "a group of asks: the page reads its permission groups over v1"),
    not("permission_reissued", "an open ask asked again after a restart: its row is open already"),
    code("permission_request", "an ask row: a permission or a question (State::ask_permission)"),
    not("permission_withdrawn", "an agent's cancel: a `cancelled` decision settles its ask"),
    card("plan_build", "plan_build", &[("plan_build", "buildId")]),
    not("policy", UNREAD),
    not("policy_refused", UNREAD),
    notice("policy_unenforced", &[]),
    not("pool_taken", UNREAD),
    code("preset_approval_decision", PATCHES),
    card(
        "preset_approval_request",
        "presetApproval",
        &[("preset_approval_decision", "preset"), ("preset_approval_request", "preset")],
    ),
    not("preset_mode_dropped", UNREAD),
    not("process_update", UNREAD),
    code("prompt_refused", "a prompt that will not run: a turn it ended ends (State::withdrawn)"),
    not("prompt_retracted", UNREAD),
    not("prompt_stop_requested", UNREAD),
    not("queue_approved", QUEUE),
    code(
        "queue_declined",
        "the queue: the entry leaves, and a turn it ended ends (State::withdrawn)",
    ),
    code("queue_order", "the queue's order, and a prompt sent now (State::interrupt)"),
    code("queue_paused", "the queue: entries held (State::queue_set_held)"),
    code(
        "queue_removed",
        "the queue: the entry leaves, and a turn it ended ends (State::withdrawn)",
    ),
    not("queue_restored", UNREAD),
    code("queue_resumed", "the queue: entries released (State::queue_set_held)"),
    not("queue_updated", QUEUE),
    code("queued", "the queue: an entry (State::queue_add)"),
    page("race"),
    not("rate_limit_held", UNREAD),
    not("rate_limit_lifted", UNREAD),
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
    code("secret_decision", "settles its ask row with its outcome (State::decide_secret)"),
    code("secret_request", "an ask row for a secret (State::ask_secret)"),
    not("secret_run", UNREAD),
    code("sender_claim", "where a prompt was sent from: its user row's `sentFrom` (State::claim)"),
    card(
        "session_offer",
        "sessionOffer",
        &[("session_offer_decision", "offerId"), ("session_offer", "groupId")],
    ),
    code("session_offer_decision", PATCHES),
    not("start_default_skipped", UNREAD),
    page("status"),
    not("stderr", UNREAD),
    code("steer_read", "a steer read: its user row settles (State::steer_read)"),
    not("steer_returned", UNREAD),
    code(
        "steer_withdrawn",
        "a steer taken back before it was read: its row goes (State::settle_prompt)",
    ),
    not("stop_escalated", UNREAD),
    not("stop_restarted", UNREAD),
    notice("stopped", &[]),
    not("stopped_while_starting", UNREAD),
    notice("stopping", &[]),
    not("subagent_retry", LIVE),
    not("subagents_running", UNREAD),
    not("subagents_working", UNREAD),
    page("subsession"),
    not("subsessions_waiting", UNREAD),
    not("summarized", UNREAD),
    not("tags", UNREAD),
    not("task_list", UNREAD),
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
            patch: &[],
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
    page("available_commands_update"),
    not("background_task_update", TOOL_BG),
    code("compaction", "a compaction notice, open while it runs"),
    page("config_option_update"),
    page("current_mode_update"),
    code("plan", "the turn's plan row (State::plan)"),
    not("prompt_suggestion", LIVE),
    page("session_info_update"),
    code("subagent_progress", "a sub row (State::sub)"),
    not("subagent_state_update", LIVE),
    not(
        "task_progress",
        "Claude's own task line, which the hub writes as subagent_progress (claude_stdio/workflows.rs)",
    ),
    code("tool_call", "a tool row (State::tool)"),
    code("tool_call_update", "a tool row (State::tool)"),
    page("usage_update"),
    not("user_message_chunk", "the prompt is the mux user_message's row"),
];

/// A kind whose `event` decides what it is (decision 241): its line above is the kind's for the
/// page-state hold, which names kinds; these name each event. None is counted as unknown.
#[cfg_attr(not(test), allow(dead_code, reason = "the table's own words, read by its tests"))]
pub(super) const EVENTS: &[(&str, &str, Draw)] = &[
    ("subsession", "limits", Draw::PageState),
    ("subsession", "started", Draw::Not(SUB)),
    ("subsession", "turn_ended", Draw::Not(SUB)),
];
const SUB: &str = "PR 4: the sub row of the `acpmux run --parent` call it stands for";

/// Every other `in` and `out` record: requests, responses and the harness's own lines.
#[cfg_attr(not(test), allow(dead_code, reason = "the table's own words, read by its tests"))]
pub(super) const PROTOCOL: &str =
    "protocol traffic: what the chat draws of it comes as mux records and updates";

/// The kinds whose disposition is page state, for the parity test to hold against the page's list.
#[cfg_attr(not(test), allow(dead_code, reason = "read by the parity test and this crate's tests"))]
pub(super) fn page_state() -> impl Iterator<Item = &'static str> {
    MUX.iter()
        .chain(UPDATES)
        .filter(|kind| matches!(kind.draw, Draw::PageState))
        .map(|kind| kind.name)
}
pub(super) fn find(table: &'static [Kind], name: &str) -> Option<&'static Kind> {
    table.binary_search_by(|kind| kind.name.cmp(name)).ok().and_then(|at| table.get(at))
}
