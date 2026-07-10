fn main() {
    let command = std::env::args().nth(1).unwrap_or_default();
    match command.as_str() {
        "__diff-viewer-refs" => println!(
            r#"{{"groups":[{{"id":"branches","label":"Branches","rows":[{{"ref":"main","label":"main","current":true}}]}}]}}"#
        ),
        "__diff-viewer-branch" => {
            println!("cmux-diff-viewer://0123456789abcdef/generated.html");
        }
        _ => std::process::exit(2),
    }
}
