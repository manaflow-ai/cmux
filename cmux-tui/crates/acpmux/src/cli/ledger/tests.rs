use super::*;

#[test]
fn params_name_the_range_and_one_group() {
    let args = LedgerArgs { since: Some("2d".into()), by: "pr".into(), limit: 5, csv: false };
    let p = params(&args, 10 * 86_400_000).unwrap();
    assert_eq!(p["since"], 8 * 86_400_000u64);
    assert_eq!(p["groupBy"], json!(["pr"]));
    assert!(params(&LedgerArgs { by: "colour".into(), ..args }, 0).is_err());
}

#[test]
fn text_lists_the_groups_most_spent_first() {
    let args = LedgerArgs { since: None, by: "repo".into(), limit: 20, csv: false };
    let answer = json!({
        "totals": {"costUsd": 3.5, "turns": 4, "sessions": 2, "harnessCostUsd": 3.0,
                   "tableCostUsd": 0.5, "unpricedTurns": 1, "cacheSavedUsd": 7.25},
        "rollups": {"repo": [
            {"key": "acme/widgets", "costUsd": 3.0, "turns": 3, "sessions": 1},
            {"key": "none", "costUsd": 0.5, "turns": 1, "sessions": 1}
        ]}
    });
    let out = text(&args, &answer);
    assert!(out.starts_with("$3.50 over 4 turns in 2 sessions"), "{out}");
    assert!(out.lines().next().unwrap().ends_with("cache reads saved $7.25)"), "{out}");
    let lines: Vec<&str> = out.lines().collect();
    assert!(lines[1].contains("$3.00") && lines[1].ends_with("acme/widgets"), "{out}");
    assert!(lines[2].ends_with("none"), "{out}");
}

#[test]
fn csv_has_a_header_and_every_group_spreadsheet_safe() {
    let args = LedgerArgs { since: None, by: "account".into(), limit: 1, csv: true };
    let answer = json!({"rollups": {"account": [
        {"key": "team, api key", "costUsd": 2.5, "cacheWriteTokens": 400,
         "cacheWrite1hTokens": 300, "cacheSavedUsd": 1.25, "turns": 3, "sessions": 1},
        {"key": "=HYPERLINK(\"x\")", "costUsd": 0.5, "turns": 1, "sessions": 1}
    ]}});
    let out = csv(&args, &answer);
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(lines.len(), 3, "--limit never cuts an export: {out}");
    assert!(lines[0].starts_with("account,label,costUsd,"), "{out}");
    assert!(lines[1].starts_with("\"team, api key\",\"team, api key\",2.5,"), "{out}");
    assert!(lines[1].contains(",1.25,3,"), "{out}");
    // The hour-long writes have their own column, after the writes they are part of.
    assert!(lines[0].contains(",cacheWriteTokens,cacheWrite1hTokens,cacheSavedUsd,"), "{out}");
    assert!(lines[1].contains(",400,300,1.25,"), "{out}");
    assert!(lines[2].contains(",0,0,0,1,"), "a group without it reads 0: {out}");
    assert!(lines[2].starts_with("\"'=HYPERLINK(\"\"x\"\")\""), "{out}");
    // A tab or line break would split the cell on paste and leave `=1+1` a cell of its own.
    assert_eq!(csv_field("audit\t=1+1\nend"), "audit =1+1 end");
}
