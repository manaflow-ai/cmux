use cmux::{Config, Result};
use cmux_sidebar::{SidebarConfig, SidebarRuntime};
use crossterm::event::{self, Event, KeyCode, KeyEventKind};
use crossterm::execute;
use crossterm::terminal::{
    EnterAlternateScreen, LeaveAlternateScreen, disable_raw_mode, enable_raw_mode,
};
use ratatui::Terminal;
use ratatui::backend::CrosstermBackend;
use std::io;
use std::time::Duration;

fn main() -> Result<()> {
    let client = cmux::Client::connect(Config::default())?;
    let session = client.current_session();
    let view_snapshot = session
        .ensure_sidebar_view(cmux::SidebarEnsureOptions {
            size: cmux::Size::new(32, 24)?,
            relaunch: None,
        })?
        .value;
    let view = session.sidebar_view(view_snapshot.id);
    let mut sidebar = SidebarRuntime::start(view, SidebarConfig::default())?;

    enable_raw_mode().map_err(io_error)?;
    let mut stdout = io::stdout();
    execute!(stdout, EnterAlternateScreen).map_err(io_error)?;
    let mut terminal = Terminal::new(CrosstermBackend::new(stdout)).map_err(io_error)?;

    let result = run(&mut terminal, &mut sidebar);
    disable_raw_mode().map_err(io_error)?;
    execute!(terminal.backend_mut(), LeaveAlternateScreen).map_err(io_error)?;
    terminal.show_cursor().map_err(io_error)?;
    sidebar.shutdown()?;
    client.close()?;
    result
}

fn run(
    terminal: &mut Terminal<CrosstermBackend<io::Stdout>>,
    sidebar: &mut SidebarRuntime,
) -> Result<()> {
    loop {
        sidebar.poll_updates();
        terminal
            .draw(|frame| frame.render_widget(sidebar.widget(), frame.area()))
            .map_err(io_error)?;
        if !event::poll(Duration::from_millis(50)).map_err(io_error)? {
            continue;
        }
        let event = event::read().map_err(io_error)?;
        if matches!(
            event,
            Event::Key(key)
                if key.kind == KeyEventKind::Press && key.code == KeyCode::Char('q')
        ) {
            return Ok(());
        }
        sidebar.handle_event(&event)?;
    }
}

fn io_error(error: io::Error) -> cmux::Error {
    cmux::Error::Connection(error.to_string())
}
