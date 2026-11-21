//! The shared entry point for agent-service v2 god-vs-small gates.
//!
//! The rows are intentionally skipped until their owning PR supplies a measurement.  Keeping the
//! entry point live means the nightly report can name every promised row from PR 0 onward.

#[path = "v2/mod.rs"]
#[allow(dead_code)]
mod home;

fn main() {
    let mut measures = Vec::new();
    let mut measures_requested = false;
    let mut output = None;
    let args: Vec<_> = std::env::args_os().skip(1).collect();
    let mut index = 0;
    while index < args.len() {
        match args[index].to_string_lossy().as_ref() {
            // Cargo passes this selector through to harness-free bench binaries.
            "--bench" => {
                if args.get(index + 1).is_some_and(|arg| !arg.to_string_lossy().starts_with("--")) {
                    index += 1;
                }
            }
            "--measures" => {
                measures_requested = true;
                index += 1;
                while index < args.len() && !args[index].to_string_lossy().starts_with("--") {
                    measures.push(std::path::PathBuf::from(&args[index]));
                    index += 1;
                }
                continue;
            }
            "--output" => {
                index += 1;
                let Some(path) = args.get(index) else {
                    eprintln!("v2 bench: --output needs a path");
                    std::process::exit(2);
                };
                output = Some(std::path::PathBuf::from(path));
            }
            argument => {
                eprintln!("v2 bench: unknown argument {argument}");
                std::process::exit(2);
            }
        }
        index += 1;
    }
    if let Err(error) =
        home::print_report_with_mode(&measures, output.as_deref(), measures_requested)
    {
        eprintln!("v2 bench: {error}");
        std::process::exit(2);
    }
}
