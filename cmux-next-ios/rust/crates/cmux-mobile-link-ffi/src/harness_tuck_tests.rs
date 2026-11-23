//! The tuck rule on the screens of real sessions: Claude Code 2.1.310, Codex 0.164.0 and
//! opencode 1.19.5 at 100 x 32 (`cmux-tui/crates/cmux-agent-cli-render/tests/fixtures`, each
//! recording replayed to the moment it names).

use super::*;

fn rows(screen: &str) -> Vec<String> {
    // The literal starts with a newline after `r#"`.
    screen.strip_prefix('\n').unwrap_or(screen).lines().map(str::to_owned).collect()
}

fn tuck(program: &str, screen: &str) -> HarnessTuck {
    let rows = rows(screen);
    assert_eq!(rows.len(), 32, "{program}: a 32 row screen");
    harness_tuck(program.to_owned(), rows)
}

/// Rows the conversation gets on a `screen_rows` screen when the block tucks: `before` is what
/// shows above the harness's chrome, `after` what shows with it tucked.
fn content_rows(t: &HarnessTuck, screen: &str) -> (usize, usize) {
    let rows = rows(screen);
    let end = rows.iter().rposition(|r| !r.trim().is_empty()).map_or(0, |i| i + 1);
    let from = t.tuck_from.map_or(end, |f| f as usize);
    (from, end)
}

#[test]
fn claude_code_tucks_its_input_box_footer_and_spinner() {
    let t = tuck("claude", CLAUDE_AFTER_APPROVAL1);
    assert_eq!(t.harness, Some(TuckHarness::Claude));
    assert!(!t.prompt);
    assert_eq!(t.tuck_from, Some(12), "from the `✻ Misting…` spinner down");
    assert!(rows(CLAUDE_AFTER_APPROVAL1)[11].trim().is_empty());
    assert!(rows(CLAUDE_AFTER_APPROVAL1)[10].contains("print(\"hi\")"), "the tool's output stays");

    let t = tuck("claude", CLAUDE_DONE);
    let r = rows(CLAUDE_DONE);
    let from = t.tuck_from.expect("a done turn tucks") as usize;
    assert!(r[from - 1].contains("Churned for"), "the turn's record stays: {:?}", r[from - 1]);
    assert!(r[from..].iter().all(|row| row.trim().is_empty()
        || rule(row)
        || row.trim_start().starts_with('❯')
        || row.starts_with("  ")));
}

#[test]
fn codex_tucks_its_prompt_line_footer_and_working_line() {
    let t = tuck("codex", CODEX_WORKING);
    let r = rows(CODEX_WORKING);
    let from = t.tuck_from.expect("working tucks") as usize;
    assert!(r[from].contains("Working ("), "{:?}", r[from]);

    let t = tuck("/opt/homebrew/bin/codex", CODEX_DONE);
    let r = rows(CODEX_DONE);
    let from = t.tuck_from.expect("done tucks") as usize;
    assert!(r[..from].iter().any(|row| row.contains("Worked for")), "the turn's record stays");
    assert!(r[from..].iter().any(|row| row.starts_with("› Ask Codex")));
}

#[test]
fn opencode_tucks_its_barred_box_and_hint_row() {
    for screen in [OPENCODE_WORKING, OPENCODE_DONE] {
        let t = tuck("opencode", screen);
        let r = rows(screen);
        let from = t.tuck_from.expect("tucks") as usize;
        assert!(r[from..].iter().any(|row| row.trim_start().starts_with('╹')));
        assert!(
            r[from..].iter().all(|row| row.trim().is_empty()
                || row.trim_start().starts_with(['┃', '╹'])
                || row.starts_with("   ")),
            "{:?}",
            &r[from..]
        );
    }
}

#[test]
fn the_phones_fake_codex_tucks_its_rule_prompt_and_status() {
    // `FakeCodexSession`'s live area (the simulator UI test's harness): a rule, `› `, a blank,
    // the status line, at the screen's bottom.
    let mut screen: Vec<String> = (1..=32).map(|n| format!("reply line {n}")).collect();
    screen.push("─".repeat(40));
    screen.push("› ".to_owned());
    screen.push(String::new());
    screen.push("Working (3s) · esc to interrupt".to_owned());
    screen.push(String::new());
    let t = harness_tuck("codex".to_owned(), screen);
    assert_eq!(t.tuck_from, Some(32));
    assert!(!t.prompt);
}

#[test]
fn a_question_the_person_must_answer_never_tucks() {
    for (program, screen) in
        [("claude", CLAUDE_APPROVAL1), ("codex", CODEX_APPROVAL1), ("opencode", OPENCODE_APPROVAL1)]
    {
        let t = tuck(program, screen);
        assert!(t.prompt, "{program}: the approval is a prompt");
        assert_eq!(t.tuck_from, None, "{program}: nothing tucks over a question");
    }
    assert!(asks_the_person("❯ 1. Yes"));
    assert!(asks_the_person("› 2. No, and tell Codex what to do differently (esc)"));
    assert!(asks_the_person("Overwrite? (y/n)"));
    assert!(!asks_the_person("❯ fix the 1. item"));
    assert!(!asks_the_person("› Ask Codex to do anything"));
}

#[test]
fn a_shell_or_an_editor_tucks_nothing() {
    for program in ["zsh", "bash", "vim", "less", "python3", ""] {
        let t = harness_tuck(program.to_owned(), rows(CLAUDE_DONE));
        assert_eq!(t, HarnessTuck { harness: None, tuck_from: None, prompt: false }, "{program}");
    }
}

#[test]
fn a_screen_that_is_only_chrome_tucks_nothing() {
    let mut r = vec![String::new(); 28];
    r.extend(["─".repeat(60), "❯ ".to_owned(), "─".repeat(60), "  ? for shortcuts".to_owned()]);
    assert_eq!(harness_tuck("claude".to_owned(), r).tuck_from, None);
}

#[test]
fn a_boxed_harness_tucks_its_rounded_box() {
    let mut r = vec!["✦ I updated the parser and ran the tests.".to_owned(), String::new()];
    r.push(format!("╭{}╮", "─".repeat(58)));
    r.push(format!("│ >   Type your message or @path/to/file{}│", " ".repeat(20)));
    r.push(format!("╰{}╯", "─".repeat(58)));
    r.push("~/src/app (main*)        no sandbox        gemini-3-pro (91% context left)".to_owned());
    let t = harness_tuck("gemini".to_owned(), r);
    assert_eq!(t.tuck_from, Some(1));
}

/// The numbers: rows the conversation gets on each real screen, before (it ends where the
/// harness's chrome starts) and after (the chrome tucked: the screen's last row).
#[test]
fn content_rows_per_harness() {
    let mut table = String::new();
    for (program, name, screen) in [
        ("claude", "claude working", CLAUDE_AFTER_APPROVAL1),
        ("claude", "claude done", CLAUDE_DONE),
        ("codex", "codex working", CODEX_WORKING),
        ("codex", "codex done", CODEX_DONE),
        ("opencode", "opencode working", OPENCODE_WORKING),
        ("opencode", "opencode done", OPENCODE_DONE),
    ] {
        let t = tuck(program, screen);
        let (from, end) = content_rows(&t, screen);
        let tucked = end - from;
        assert!(tucked >= 3, "{name}: at least the box tucks ({tucked})");
        table.push_str(&format!("{name}: {tucked} chrome rows tucked\n"));
    }
    println!("{table}");
}

const CLAUDE_AFTER_APPROVAL1: &str = r#"
u ▐▛███▛█  Claude Code v2.1.310
▝▜██████▀  Opus 5.5 · API Usage Billing
 ▝▝   ▝▝   /tmp/clirender.4kNY/work


❯ Create hello.py that prints hi. Then use the Edit tool to change it to print hello. Then run it
  with python3. Keep replies to one line.

● Write(hello.py)
  ⎿  Wrote 1 line to hello.py
      1 print("hi")

✻ Misting… (4s · ↓ 93 tokens)

────────────────────────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏸ manual mode on · esc to interrupt
  tmux focus-events off · add 'set -g focus-events on' to ~/.tmux.conf and reattach for focus tra…













"#;

const CLAUDE_APPROVAL1: &str = r#"
u ▐▛███▛█  Claude Code v2.1.310
▝▜██████▀  Opus 5.5 · API Usage Billing
 ▝▝   ▝▝   /tmp/clirender.4kNY/work


❯ Create hello.py that prints hi. Then use the Edit tool to change it to print hello. Then run it
  with python3. Keep replies to one line.

● Write(hello.py)

────────────────────────────────────────────────────────────────────────────────────────────────────
 Create file
 hello.py
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
  1 print("hi")
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to create hello.py?
 ❯ 1. Yes
   2. Yes, and switch to accept edits (auto-approve file edits and common file commands) for this
      session (shift+tab)
   3. No

 Esc to cancel · Tab to amend









"#;

const CLAUDE_DONE: &str = r#"
 ▐▛███▛█   Claude Code v2.1.310
▝▜██████▀  Opus 5.5 · API Usage Billing
 ▝▝   ▝▝   /tmp/clirender.4kNY/work


❯ Create hello.py that prints hi. Then use the Edit tool to change it to print hello. Then run it
  with python3. Keep replies to one line.

● Write(hello.py)
  ⎿  Wrote 1 line to hello.py
      1 print("hi")

● Update(hello.py)
  ⎿  Added 1 line, removed 1 line
      1 -print("hi")
      1 +print("hello")

● Bash(python3 /tmp/clirender.4kNY/work/hello.py)
  ⎿  hello

● I created hello.py, edited it to print hello, and running it with python3 printed hello.

✻ Churned for 8s · done 8:37 PM

────────────────────────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────────────────────────
  ⏸ manual mode on · ? for shortcuts                                            ◐ medium · /effort




"#;

const CODEX_WORKING: &str = r#"

  >_ OpenAI Codex (v0.164.0)
     /tmp/hybrid.K7J3/work2


› Create hello.py that prints hi. Then edit it to print hello. Then run it with python3. Keep
  replies to one line.


• I’ll create, edit, and run hello.py now.















• Working (3s • esc to interrupt)


› Ask Codex to do anything

  GPT-6-Astra low · /tmp/hybrid.K7J3/work2 · Create, update, and run hello.py
  ← for agents · ? for shortcuts
"#;

const CODEX_APPROVAL1: &str = r#"

  >_ OpenAI Codex (v0.164.0)
     /tmp/hybrid.K7J3/work2


› Create hello.py that prints hi. Then edit it to print hello. Then run it with python3. Keep
  replies to one line.


• I’ll create, edit, and run hello.py now.

• Running printf 'print("hi")\n' > hello.py






  Would you like to run the following command?

  Environment: local

  Reason: May I create and edit hello.py in the workspace?

  $ printf 'print("hi")\n' > hello.py


› 1. Yes, proceed (y)
  2. Yes, and don't ask again for commands that start with `printf 'print("hi")\n' > hello.py` (p)
  3. No, and tell Codex what to do differently (esc)

  Press enter to confirm or esc to cancel
"#;

const CODEX_DONE: &str = r#"
  >_ OpenAI Codex (v0.164.0)
     /tmp/hybrid.K7J3/work2


› Create hello.py that prints hi. Then edit it to print hello. Then run it with python3. Keep
  replies to one line.


• I’ll create, edit, and run hello.py now.

✔ You approved codex to run printf 'print("hi")\n' > hello.py this time

• Ran printf 'print("hi")\n' > hello.py
  └ (no output)

✔ You approved codex to run printf 'print("hello")\n' > hello.py this time

• Ran printf 'print("hello")\n' > hello.py
  └ (no output)

• Ran python3 hello.py
  └ hello

• Created and edited hello.py; running it produced hello.

  Worked for 18s • 10:07 PM


› Ask Codex to do anything

  GPT-6-Astra low · /tmp/hybrid.K7J3/work2 · Create, update, and run hello.py
  ← for agents · ? for shortcuts
"#;

const OPENCODE_WORKING: &str = r#"

  ┃
  ┃  Create hello.py that prints hello. Then change it to print hello world. Then run it with
  ┃  python3.
  ┃

     Thought · 1ms

     ~ Updating todos…

     ▣  Build · Model Alpha














  ┃
  ┃
  ┃
  ┃  Build · Model Alpha Vendor
  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
   ⬝⬝⬝⬝⬝⬝⬝⬝  esc interrupt                                             tab agents  ctrl+p commands

"#;

const OPENCODE_APPROVAL1: &str = r#"

  ┃
  ┃  Create hello.py that prints hello. Then change it to print hello world. Then run it with
  ┃  python3.
  ┃

     Thought · 1ms

  ┃
  ┃  # Todos
  ┃
  ┃  [•] Create hello.py printing hello
  ┃  [ ] Change hello.py to print hello world
  ┃  [ ] Run hello.py with python3
  ┃

     I’ll create the script, update its output, then execute it with python3.

     $ ls -la

     ▣  Build · Model Alpha

  ┃
  ┃  △ Permission required
  ┃    # Shell command
  ┃
  ┃  $ ls -la
  ┃
  ┃
  ┃   Allow once   Allow always   Reject             ctrl+f fullscreen  ⇆ select  enter confirm
  ┃

"#;

const OPENCODE_DONE: &str = r#"
  ┃  [•] Run hello.py with python3
  ┃

  ┃
  ┃  $ python3 hello.py
  ┃
  ┃  hello world
  ┃

  ┃
  ┃  # Todos
  ┃
  ┃  [✓] Create hello.py printing hello
  ┃  [✓] Change hello.py to print hello world
  ┃  [✓] Run hello.py with python3
  ┃

     Created and updated hello.py to print:

     hello world

     Ran it with python3 successfully.

     ▣  Build · Model Alpha · 28.4s

  ┃
  ┃
  ┃
  ┃  Build · Model Alpha Vendor
  ╹▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀
   /tmp/agent-demo1/work                                        6.2K (1%) · $0.20  ctrl+p commands

"#;
