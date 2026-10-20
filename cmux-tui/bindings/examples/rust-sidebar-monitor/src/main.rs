use cmux::{Client, Config, Result, SidebarEnsureOptions, Size};
use cmux_sidebar_monitor_example::{MonitorConfig, SidebarMonitor};
use crossterm::event::{self, Event, KeyCode, KeyEventKind};
use crossterm::execute;
use crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode, size,
};
use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use std::io;
use std::time::Duration;

fn main() -> Result<()> {
    let client = Client::connect(Config::default())?;
    let session = client.current_session();
    let (columns, rows) = size().map_err(io_error)?;
    let snapshot = session
        .ensure_sidebar_view(SidebarEnsureOptions {
            size: Size::new(columns.max(1), rows.max(1))?,
            relaunch: None,
        })?
        .value;
    let view = session.sidebar_view(snapshot.id);
    let mut monitor = SidebarMonitor::start(view, MonitorConfig::default())?;

    enable_raw_mode().map_err(io_error)?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen).map_err(io_error)?;
    let mut terminal = Terminal::new(CrosstermBackend::new(stdout)).map_err(io_error)?;

    let run_result = run(&mut terminal, &mut monitor);
    let shutdown_result = monitor.shutdown();
    let raw_result = disable_raw_mode().map_err(io_error);
    let screen_result = execute!(terminal.backend_mut(), LeaveAlternateScreen).map_err(io_error);
    let cursor_result = terminal.show_cursor().map_err(io_error);
    let close_result = client.close();

    run_result?;
    shutdown_result?;
    raw_result?;
    screen_result?;
    cursor_result?;
    close_result
}

fn run(
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    monitor: &mut SidebarMonitor,
) -> Result<()> {
    loop {
        monitor.poll_updates()?;
        terminal
            .draw(|frame| frame.render_widget(monitor.widget(), frame.area()))
            .map_err(io_error)?;
        if monitor.status().is_terminal() {
            return Ok(());
        }
        if !event::poll(Duration::from_millis(50)).map_err(io_error)? {
            continue;
        }
        let input = event::read().map_err(io_error)?;
        if matches!(
            input,
            Event::Key(key)
                if key.kind == KeyEventKind::Press
                    && matches!(key.code, KeyCode::Char('q') | KeyCode::Esc)
        ) {
            return Ok(());
        }
        if matches!(
            input,
            Event::Key(key)
                if key.kind == KeyEventKind::Press && key.code == KeyCode::Char('r')
        ) {
            monitor.reload()?;
            continue;
        }
        monitor.handle_event(&input)?;
    }
}

fn io_error(error: io::Error) -> cmux::Error {
    let message = error.to_string();
    let _ = error.into_inner();
    cmux::Error::Connection(message)
}
