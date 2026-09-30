//! The `acpmux` command line, split from `main.rs`: `run` dispatches a
//! parsed command; `output` formats what the daemon answers; `orchestrate`
//! holds the commands other agents and scripts call; `errors` maps every
//! failure to one exit code and envelope.

pub mod errors;
pub mod hosts;
pub mod orchestrate;
pub mod output;
pub mod run;
