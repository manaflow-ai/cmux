use super::*;
use serde_json::json;

const NOW: u64 = 1_800_000_000_000;

fn lane(name: &str) -> Value {
    json!({"name": name, "titleSource": "named", "harness": "claude", "status": "running",
           "state": "running", "turnCount": 3, "updatedAt": NOW - 5_000, "parentId": null,
           "pendingPermissions": 0, "stuckReason": null, "lane": {"state": "working"},
           "lastPrompt": "a long brief", "tags": {}})
}

fn with(mut row: Value, patch: Value) -> Value {
    for (k, v) in patch.as_object().unwrap() {
        row[k] = v.clone();
    }
    row
}

fn compact(rows: &[Value]) -> String {
    render(rows, Some(&[]), View::default(), false, NOW)
}

#[test]
fn the_default_lists_only_live_named_lanes_and_counts_the_rest() {
    let rows = vec![
        lane("ao-cli-ls"),
        with(lane("old"), json!({"status": "closed", "state": "closed"})),
        with(lane("review-27899"), json!({"harness": "codex-review-box"})),
        with(lane("rev-tagged"), json!({"harness": "codex", "tags": {"review.verdict": "SHIP"}})),
        with(lane("child"), json!({"parentId": "01a1"})),
        with(lane("codex-2"), json!({"harness": "codex", "titleSource": "harness"})),
        with(lane(""), json!({})),
    ];
    let out = compact(&rows);
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(lines[0], "NAME       STATE    TURNS  AGE", "{out}");
    assert_eq!(lines[1], "ao-cli-ls  running  3      5s", "{out}");
    assert_eq!(
        lines[2],
        "6 more hidden (1 closed, 2 reviewers, 1 sub-sessions, 2 unnamed): acpmux ls --all"
    );
    assert_eq!(lines.len(), 3, "{out}");
}

#[test]
fn all_lists_the_hidden_rows_and_a_filter_hides_none() {
    let rows = vec![lane("a"), with(lane("old"), json!({"status": "closed", "state": "closed"}))];
    let all = render(&rows, Some(&[]), View { all: true, wide: false }, false, NOW);
    let old_row = |out: &str| out.lines().any(|l| l.starts_with("old ") && l.contains(" closed "));
    assert!(old_row(&all), "{all}");
    assert!(!all.contains("hidden"), "{all}");
    let filtered = render(&rows, Some(&[]), View::default(), true, NOW);
    assert!(old_row(&filtered), "{filtered}");
}

#[test]
fn a_named_session_whose_name_looks_generated_is_kept() {
    // Someone ran `acpmux new -n codex-2`: the daemon marks it launched, or named once renamed.
    for source in ["launched", "named"] {
        let named = with(lane("codex-2"), json!({"harness": "codex", "titleSource": source}));
        assert!(compact(&[named]).contains("codex-2"), "{source}");
    }
    // A lane named after its harness and more is someone's name too.
    let lane_name =
        with(lane("codex-review"), json!({"harness": "codex", "titleSource": "harness"}));
    assert!(compact(&[lane_name]).contains("codex-review"));
}

#[test]
fn stuck_says_why_in_a_few_words() {
    let cases = [
        (json!({"pendingPermissions": 1}), "waiting", "permission"),
        (json!({"pendingPermissions": 2}), "waiting", "2 permissions"),
        (json!({"state": "stuck", "stuckReason": "capacity"}), "stuck", "capacity"),
        (json!({"state": "stuck", "stuckReason": "harness_unavailable"}), "stuck", "harness down"),
        (json!({"state": "idle", "lane": {"state": "failed"}}), "idle", "failed turn"),
        (
            json!({"lane": {"state": "working", "stalledSince": NOW - 12 * 60_000}}),
            "running",
            "stalled 12m",
        ),
    ];
    for (patch, state, why) in cases {
        let out = compact(&[with(lane("x"), patch.clone())]);
        let row = out.lines().nth(1).unwrap();
        let cells: Vec<&str> = row.split("  ").filter(|c| !c.is_empty()).map(str::trim).collect();
        assert_eq!(cells[1], state, "{patch}: {out}");
        assert_eq!(cells.last().copied(), Some(why), "{patch}: {out}");
        assert!(out.starts_with("NAME  STATE"), "{out}");
        assert!(out.lines().next().unwrap().ends_with("STUCK"), "{out}");
    }
}

#[test]
fn host_shows_only_when_a_row_is_on_a_peer() {
    assert!(!compact(&[lane("a")]).contains("HOST"));
    let peer = with(lane("b"), json!({"peer": "huge-blue", "peerState": "connected"}));
    let out = compact(&[lane("a"), peer]);
    assert!(out.lines().next().unwrap().starts_with("NAME  HOST"), "{out}");
    assert!(out.contains("b     huge-blue"), "{out}");
    assert!(out.contains("a     -"), "{out}");
}

#[test]
fn an_unreachable_peer_reads_unknown_and_is_never_dropped() {
    let stale = with(
        lane("far"),
        json!({"peer": "cmux16", "peerState": "offline", "stale": true, "state": "running"}),
    );
    let peers = [
        json!({"name": "cmux16", "state": "offline", "downSince": NOW - 3 * 60_000}),
        json!({"name": "air-blue", "state": "reconnecting", "downSince": null}),
        json!({"name": "huge-blue", "state": "connected"}),
    ];
    let out = render(&[stale], Some(&peers), View::default(), false, NOW);
    let row = out.lines().nth(1).unwrap();
    assert!(row.contains("unknown") && row.ends_with("peer offline"), "{out}");
    assert!(
        out.contains("UNKNOWN cmux16: peer offline for 3m; its sessions are last known, not live"),
        "{out}"
    );
    // A down peer with no rows at all still gets its line.
    assert!(out.contains("UNKNOWN air-blue: peer reconnecting;"), "{out}");
    assert!(!out.contains("huge-blue"), "{out}");
    // Peer states that could not be read are said, not taken as none down.
    let unread = render(&[lane("a")], None, View::default(), false, NOW);
    assert!(unread.contains("UNKNOWN peers: their link states could not be read"), "{unread}");
}

#[test]
fn warn_is_one_word_and_shows_only_while_a_row_has_one() {
    assert!(!compact(&[lane("a")]).contains("WARN"));
    // Warnings as the daemon decides them (`hub/usage_warnings.rs`), for a row named `big`.
    let stats = json!({"autocompact": "none", "contextTokens": 955_000, "subagents1h": 90});
    let summary = json!({"name": "big", "status": "idle", "family": "claude", "usageStats": stats});
    let warnings = crate::hub::usage_warnings::usage_warnings(
        &summary,
        &crate::config::UsageLimits::default(),
    );
    let warned = with(lane("big"), json!({"usageWarnings": warnings}));
    let out = compact(&[lane("a"), warned.clone()]);
    assert!(out.lines().next().unwrap().ends_with("WARN"), "{out}");
    assert!(out.lines().any(|l| l.starts_with("big") && l.ends_with("warn")), "{out}");
    let wide = render(&[warned], Some(&[]), View { all: false, wide: true }, false, NOW);
    // Wide names each rule with its number and the command that answers it.
    assert!(
        wide.contains(
            "no-cap: lane-place rotate big --harness claude-sr2; \
             ctx 955k: acpmux send big /compact | lane-place rotate big; \
             90 sub/h: acpmux session cancel big"
        ),
        "{wide}"
    );
}

#[test]
fn wide_prints_every_column() {
    let out = render(&[lane("a")], Some(&[]), View { all: false, wide: true }, false, NOW);
    let header = "NAME  AGENT   STATUS   TURNS  AGE  STUCK  LAUNCHER  CAP  CTX  CMP  SUBS  TOK24H  $24H  LAST";
    assert_eq!(out.lines().next(), Some(header), "{out}");
    assert!(out.lines().nth(1).unwrap().ends_with("a long brief"), "{out}");
}

#[test]
fn an_empty_daemon_and_an_all_hidden_list_say_so() {
    assert!(compact(&[]).starts_with("no sessions (create one:"));
    let closed = with(lane("old"), json!({"status": "closed", "state": "closed"}));
    let out = compact(&[closed]);
    assert!(out.starts_with("no live named sessions\n"), "{out}");
    assert!(out.ends_with("1 more hidden (1 closed): acpmux ls --all\n"), "{out}");
}

#[test]
fn a_filter_that_matches_nothing_still_names_the_down_peers() {
    // `acpmux ls --host air-blue` with air-blue down and no rows cached from it.
    let peers = [json!({"name": "air-blue", "state": "offline"})];
    let out = render(&[], Some(&peers), View::default(), true, NOW);
    assert!(out.starts_with("no sessions match these filters\n"), "{out}");
    assert!(out.contains("UNKNOWN air-blue: peer offline;"), "{out}");
}

#[test]
fn every_view_keeps_the_daemons_order() {
    let closed = with(lane("old"), json!({"status": "closed", "state": "closed"}));
    let rows = [lane("newest"), closed, lane("oldest")];
    let order = |out: &str| -> Vec<String> {
        out.lines().skip(1).map(|l| l.split_whitespace().next().unwrap().to_owned()).collect()
    };
    let all = render(&rows, Some(&[]), View { all: true, wide: false }, false, NOW);
    assert_eq!(order(&all), ["newest", "old", "oldest"], "{all}");
    let filtered = render(&rows, Some(&[]), View::default(), true, NOW);
    assert_eq!(order(&filtered), ["newest", "old", "oldest"], "{filtered}");
}

#[test]
fn wide_usage_cells_say_unknown_as_a_question_mark() {
    let row = json!({"usageStats": {"launcher": "claude-sr2", "autocompact": "none",
        "autocompactCap": null, "contextTokens": 312_400, "compactions24h": 3,
        "subagentsLive": 4, "subagents24h": 90, "tokens24h": 1_234_567_890u64,
        "costUsd24h": 1234.5}});
    assert_eq!(usage(&row), ["claude-sr2", "none", "312k", "3", "4/90", "1234.6M", "$1234"]);
    let capped = json!({"usageStats": {"autocompact": "capped", "autocompactCap": 200_000,
        "contextTokens": 0, "compactions24h": 0, "subagentsLive": 0, "subagents24h": 0,
        "tokens24h": 0, "costUsd24h": null, "launcher": "claude"}});
    assert_eq!(usage(&capped), ["claude", "200k", "0", "0", "0/0", "0", "?"]);
    // Read but not known (a cut first read, an adopted chat's flags): `?`, never 0.
    let unread = json!({"usageStats": {"autocompact": "unknown", "autocompactCap": null,
        "contextTokens": 9_000, "compactions24h": null, "subagentsLive": null,
        "subagents24h": null, "tokens24h": null, "costUsd24h": null, "launcher": null}});
    assert_eq!(usage(&unread), ["?", "?", "9k", "?", "?/?", "?", "?"]);
    // A cap is known to be set but not its value: what is known, the rest `?`.
    let set = json!({"usageStats": {"autocompact": "capped", "autocompactCap": null}});
    assert_eq!(usage(&set)[1], "capped");
    assert_eq!(usage(&json!({})), ["?", "?", "?", "?", "?/?", "?", "?"]);
    // The wide table puts them before LAST; the compact one has none.
    let out =
        render(&[with(lane("a"), row)], Some(&[]), View { all: false, wide: true }, false, NOW);
    assert!(out.lines().nth(1).unwrap().contains("claude-sr2  none  312k"), "{out}");
    assert!(!compact(&[lane("a")]).contains("LAUNCHER"));
}

#[test]
fn a_short_or_empty_row_pads_without_panicking() {
    let s = |cells: &[&str]| cells.iter().map(|c| (*c).to_owned()).collect::<Vec<_>>();
    assert_eq!(table(vec![]), "");
    assert_eq!(
        table(vec![s(&["NAME", "STATUS", "AGE"]), s(&["a"]), s(&[])]),
        "NAME  STATUS  AGE\na\n\n"
    );
    // A row longer than the header: its extra cells are padded to no width.
    assert_eq!(table(vec![s(&["A", "B"]), s(&["x", "y", "z"])]), "A  B\nx  yz\n");
}

#[test]
fn a_lane_keeps_its_row_once_its_chat_is_titled() {
    // A lane started under a name gets a generated title after its first prompt (`titles.rs`);
    // ls lists it by its name, as before, also one named like the daemon's `HARNESS-N` default.
    for name in ["p0m-as-p2", "codex-2"] {
        for source in ["launched", "prompt", "asked", "generated", "harness"] {
            let row = with(
                lane(name),
                json!({"harness": "codex", "nameGiven": true, "titleSource": source,
                       "title": "Fix the rail"}),
            );
            let out = compact(&[row]);
            let listed = out.lines().nth(1).is_some_and(|l| l.starts_with(&format!("{name} ")));
            assert!(listed, "{name} {source}: {out}");
            assert!(!out.contains("hidden"), "{name} {source}: {out}");
        }
    }
    // The daemon's own name stays hidden once the chat is titled.
    let unnamed = with(lane("codex-2"), json!({"harness": "codex", "titleSource": "generated"}));
    assert!(compact(&[unnamed]).contains("1 unnamed"));
}
