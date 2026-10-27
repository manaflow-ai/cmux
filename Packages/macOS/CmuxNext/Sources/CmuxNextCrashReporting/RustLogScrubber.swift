import Foundation

/// Takes file paths and URLs out of the text of a Rust panic or hang record before it is sent
/// (p10-stability-150). A panic message often names the file it failed on, and a backtrace
/// names the build machine's checkout; neither may leave the person's Mac.
///
/// An absolute path (`/…` or `~/…`) becomes `<path>`. A Rust source file under a known build root
/// keeps its crate relative part (a cmux workspace crate `acpmux/src/hub/mod.rs:941:5`, a cargo
/// registry or git checkout `<cargo>/tokio-1.53.1/src/lib.rs:10`) so frames and panic sites stay
/// readable, and the compiler's remapped `/rustc/<hash>/…` std paths are kept as they are. Any other
/// Rust source becomes `<path>/<file>.rs:line`. A URL becomes `<url>`. Like Crashpad, which uploads
/// module names and never their paths (third_party/crashpad/crashpad/snapshot/module_snapshot.h),
/// the stack's image is reduced to its file name.
struct RustLogScrubber: Sendable {
    /// Characters a path or URL never continues through.
    private static let terminators: Set<Character> = [
        " ", "\t", "\n", "\r", "\r\n", "\"", "'", "`", "(", ")", "<", ">", "[", "]", "{", "}", ",", ";",
    ]
    /// Characters after which a path or URL may start.
    private static let starters: Set<Character> = [
        " ", "\t", "\n", "\r", "\r\n", "\"", "'", "`", "(", "<", "[", "{", "=", ",", ";", ":",
    ]

    /// `text` with every path and URL replaced.
    func scrub(_ text: String) -> String {
        let characters = Array(text)
        var output = ""
        output.reserveCapacity(text.utf8.count)
        var index = 0
        while index < characters.count {
            let atStart = index == 0 || Self.starters.contains(characters[index - 1])
            if atStart, let end = Self.urlEnd(characters, from: index) {
                output += "<url>"
                index = end
            } else if atStart, Self.startsPath(characters, at: index) {
                let end = Self.pathEnd(characters, from: index)
                output += Self.replacement(forPath: String(characters[index..<end]))
                index = end
            } else {
                output.append(characters[index])
                index += 1
            }
        }
        return output
    }

    /// The file name of a stack frame's image, never its folder.
    func imageName(_ image: String) -> String {
        image.split(separator: "/").last.map(String.init) ?? image
    }

    private static func startsPath(_ characters: [Character], at index: Int) -> Bool {
        let first = characters[index]
        if first == "/" { return true }
        return first == "~" && index + 1 < characters.count && characters[index + 1] == "/"
    }

    /// The end of a path from `start`. It runs across one space when the next word holds a
    /// slash, so `~/Library/Application Support/acpmux/x.json` is one path.
    private static func pathEnd(_ characters: [Character], from start: Int) -> Int {
        var end = start
        while end < characters.count {
            if !terminators.contains(characters[end]) {
                end += 1
                continue
            }
            guard characters[end] == " " else { break }
            var word = end + 1
            while word < characters.count, !terminators.contains(characters[word]) { word += 1 }
            let next = characters[(end + 1)..<word]
            guard let first = next.first, first != "/", first != "~", next.contains("/") else { break }
            end = word
        }
        return end
    }

    /// The end of a URL (`scheme://…`) that starts at `start`, nil when none does.
    private static func urlEnd(_ characters: [Character], from start: Int) -> Int? {
        var index = start
        while index < characters.count,
              characters[index].isASCII,
              characters[index].isLetter || (index > start && (characters[index].isNumber
                  || "+-.".contains(characters[index]))) {
            index += 1
        }
        guard index > start, index + 2 < characters.count, characters[index] == ":",
              characters[index + 1] == "/", characters[index + 2] == "/" else { return nil }
        index += 3
        while index < characters.count, !terminators.contains(characters[index]) { index += 1 }
        return index
    }

    private static func replacement(forPath raw: String) -> String {
        // A sentence's period or a label's colon after the path stays in the text.
        let path = raw.trimmingSuffix { $0 == "." || $0 == ":" }
        let trailing = String(raw.dropFirst(path.count))
        // A lone slash is a word (`a / b`); remapped std paths hold no user data.
        if path.count < 2 || path.hasPrefix("/rustc/") { return raw }
        let components = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let last = components.last, isRustSource(last) else { return "<path>" + trailing }
        // `.cargo/registry/src/<index>/<crate-version>/…` keeps the crate on,
        // `.cargo/git/checkouts/<repo>/<rev>/…` the repository on.
        if let cargo = components.firstIndex(of: ".cargo"), components.count > cargo + 4 {
            let kind = Array(components[(cargo + 1)...(cargo + 2)])
            if kind == ["registry", "src"] || kind == ["git", "checkouts"] {
                let keep = kind[0] == "registry" ? cargo + 4 : cargo + 3
                return "<cargo>/" + components[keep...].joined(separator: "/") + trailing
            }
        }
        // A cmux workspace crate, `…/cmux-tui/crates/<crate>/src/…`, keeps the crate on. Any other
        // folder may be an account or a private project name, so only the file name stays.
        if let crates = components.indices.last(where: { index in
            index > 0 && index + 2 < components.count && components[index] == "crates"
                && components[index - 1] == "cmux-tui" && components[index + 2] == "src"
        }) {
            return components[(crates + 1)...].joined(separator: "/") + trailing
        }
        return "<path>/" + last + trailing
    }

    /// `name.rs`, with an optional `:line` or `:line:col`.
    private static func isRustSource(_ component: String) -> Bool {
        let parts = component.split(separator: ":", omittingEmptySubsequences: false)
        guard let name = parts.first, name.hasSuffix(".rs"), name.count > 3, parts.count <= 3 else { return false }
        return parts.dropFirst().allSatisfy { !$0.isEmpty && $0.allSatisfy(\.isASCII) && $0.allSatisfy(\.isNumber) }
    }
}

private extension String {
    /// The string without its longest suffix of characters that match `drop`.
    func trimmingSuffix(while drop: (Character) -> Bool) -> String {
        var end = endIndex
        while end > startIndex, drop(self[index(before: end)]) { end = index(before: end) }
        return String(self[..<end])
    }
}
