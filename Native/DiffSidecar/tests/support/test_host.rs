fn main() {
    let arguments = std::env::args().collect::<Vec<_>>();
    let command = arguments.get(1).map(String::as_str).unwrap_or_default();
    match command {
        "__diff-viewer-refs" => println!(
            r#"{{"groups":[{{"id":"suggested","label":"Suggested","rows":[{{"ref":"HEAD","label":"HEAD","current":true}}]}}]}}"#
        ),
        "__diff-viewer-branch" => {
            let base = arguments
                .windows(2)
                .find_map(|pair| (pair[0] == "--base").then_some(pair[1].as_str()));
            if base == Some("malformed") {
                println!("cmux-diff-viewer://0123456789abcdef/../not-allowed.html");
            } else {
                println!("cmux-diff-viewer://0123456789abcdef/generated.html");
            }
        }
        _ => std::process::exit(2),
    }
}
