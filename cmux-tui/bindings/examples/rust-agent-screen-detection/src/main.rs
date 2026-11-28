//! `cmux-agent-screen-detection`: the standalone plugin binary (the npm
//! packages, the Linux tree and the integration tests run it). The cmux-next
//! app runs the same code from bin/cmux by argv[0] ([`cli::run`]).

use cmux_agent_screen_detection::cli;
use std::process::ExitCode;

fn main() -> ExitCode {
    cli::run(std::env::args().skip(1).collect())
}
