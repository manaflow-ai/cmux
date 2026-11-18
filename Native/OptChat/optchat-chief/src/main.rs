//! `optchat-chief`: the OptChat Chief host, its MCP memory tools and its
//! `agents` verbs. See README.md. The command line is the library's
//! (`entry.rs`), so the multicall `bin/cmux` runs the same one under this name.

fn main() -> std::process::ExitCode {
    optchat_chief::entry::main()
}
