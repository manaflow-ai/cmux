//! The TUI's lists draw only their visible rows: a frame's work (items walked, cloned, rows
//! built) is flat in the number of sessions or transcript items (cmux-view-rows frame_work).
//! Each list is drawn at N = 100 and N = 10,000 into a TestBackend; the frame measured is the
//! one after a warm-up frame, with nothing changed between them (an idle tick, a hover).
//!
//! To register a list: count its row-building points under `#[cfg(test)]` with
//! `cmux_view_rows::frame_work::{walked, cloned, built}`, then add a test here that calls
//! `contract(name, Expect::Flat | Expect::Grows(baseline), |n| { set up n; draw; measure(draw) })`.

use cmux_view_rows::frame_work::{Expect, FrameWork, contract, measure};

use super::*;

fn session(n: usize) -> Value {
    json!({"sessionId": format!("s-{n:05}"), "name": format!("session {n}"),
           "cwd": format!("/work/project-{}", n % 20), "status": "idle", "updatedAt": n})
}

fn frame(terminal: &mut ratatui::Terminal<ratatui::backend::TestBackend>, app: &mut App) {
    terminal.draw(|f| render::draw(f, app)).unwrap();
}

/// The sidebar at `n` sessions: the work of the frame after the first.
async fn sidebar_at(n: usize) -> FrameWork {
    let (mut app, _requests) = interaction_tests::app().await;
    app.drafts.clear();
    app.sessions = (0..n).map(session).collect();
    app.selected = 0;
    let mut terminal = ratatui::Terminal::new(ratatui::backend::TestBackend::new(140, 40)).unwrap();
    frame(&mut terminal, &mut app);
    measure(|| frame(&mut terminal, &mut app))
}

/// The transcript at `n` items: the work of the frame after the first.
async fn transcript_at(n: usize) -> FrameWork {
    let (mut app, _requests) = interaction_tests::app().await;
    app.drafts.clear();
    let id = "test-session";
    app.sessions = vec![json!({"sessionId": id, "name": "one"})];
    app.selected = 0;
    let mut transcript = Transcript::default();
    for i in 0..n {
        transcript.items.push(Item::User {
            text: format!("question {i}"),
            steer: false,
            queued: false,
        });
        transcript.items.push(Item::Assistant { text: format!("answer {i}") });
    }
    app.transcripts.insert(id.into(), transcript);
    let mut terminal = ratatui::Terminal::new(ratatui::backend::TestBackend::new(140, 40)).unwrap();
    frame(&mut terminal, &mut app);
    measure(|| frame(&mut terminal, &mut app))
}

/// Runs `at` for each size on this thread (the counters are per thread).
fn sizes<F, Fut>(at: F) -> impl FnMut(usize) -> FrameWork
where
    F: Fn(usize) -> Fut,
    Fut: std::future::Future<Output = FrameWork>,
{
    move |n| {
        tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap().block_on(at(n))
    }
}

/// Baseline: the transcript draws only its visible rows, but each frame looks for a pending
/// permission (`Transcript::pending_permission`, from `render::draw` and `live_answering`) by
/// reading items from the newest until it finds one: with none pending, every item, about four
/// times a frame (#46143 review P1-F1). Cache the pending permission, then flip to `Expect::Flat`.
#[test]
fn the_transcript_draws_only_its_visible_rows() {
    contract(
        "acpmux transcript",
        Expect::Grows(
            "its pending-permission scan reads every item; cache it, then flip to Expect::Flat",
        ),
        sizes(transcript_at),
    )
    .unwrap();
}

/// Baseline: the sidebar copies every session's JSON, filters and groups them all, and builds an
/// entry for each, every frame (and every 80 ms tick while a turn runs, run.rs).
#[test]
fn the_sidebar_is_a_known_whole_list_draw() {
    contract(
        "acpmux sidebar",
        Expect::Grows("fix in lane visible-only-ios-rust-lists, then flip to Expect::Flat"),
        sizes(sidebar_at),
    )
    .unwrap();
}
