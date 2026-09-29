import Foundation

/// Debug-only auto sign-in for tagged builds (parity with the old app's
/// `DebugDogfoodCredentialResolver`). A tagged build has its own Keychain
/// service, so it starts signed out; the dogfood account from
/// `~/.secrets/cmuxterm-dev.env` (then `~/.secrets/cmux.env`, then the
/// environment) is handed to `AuthCoordinator`'s existing auto-login through
/// the `CMUX_UITEST_STACK_*` launch keys. Values never leave this process
/// and are never logged. `CMUX_AUTH_CREDENTIALS_FILE` (baked by
/// `reload.sh --credentials-file`) is the only source when present.
/// `CMUX_DEV_AUTH_PROFILE` picks `personal` (dogfood keys) or `agent`
/// (uitest keys).
struct DogfoodCredentials: Equatable {
    let email: String
    let password: String

    static func resolve(environment: [String: String], home: String,
                        read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> DogfoodCredentials? {
        if let explicit = environment["CMUX_AUTH_CREDENTIALS_FILE"], !explicit.isEmpty {
            guard secure(explicit), let text = read(explicit) else { return nil }
            let values = parse(text)
            return pair(values, prefix: "CMUX_DOGFOOD_STACK") ?? pair(values, prefix: "CMUX_UITEST_STACK")
        }
        let prefixes: [String] = switch environment["CMUX_DEV_AUTH_PROFILE"]?.lowercased() {
        case nil, "": ["CMUX_DOGFOOD_STACK", "CMUX_UITEST_STACK"]
        case "personal": ["CMUX_DOGFOOD_STACK"]
        case "agent": ["CMUX_UITEST_STACK"]
        default: []
        }
        let files = ["\(home)/.secrets/cmuxterm-dev.env", "\(home)/.secrets/cmux.env"].compactMap(read).map(parse)
        for prefix in prefixes {
            for values in files { if let found = pair(values, prefix: prefix) { return found } }
            if let found = pair(environment, prefix: prefix) { return found }
        }
        return nil
    }

    /// A complete pair from one source; never mixes sources.
    private static func pair(_ values: [String: String], prefix: String) -> DogfoodCredentials? {
        guard let email = values["\(prefix)_EMAIL"], !email.isEmpty,
              let password = values["\(prefix)_PASSWORD"], !password.isEmpty else { return nil }
        return DogfoodCredentials(email: email, password: password)
    }

    /// `KEY=value` lines; `export`, quotes, and comments tolerated.
    static func parse(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for raw in text.split(whereSeparator: \.isNewline) {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            if line.hasPrefix("export ") { line = String(line.dropFirst(7)) }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces)
            var value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value = String(value.dropFirst().dropLast())
            }
            values[key] = value
        }
        return values
    }

    /// The explicit file must be a regular file owned by this user, 0600 or stricter.
    private static func secure(_ path: String) -> Bool {
        var info = stat()
        guard lstat(path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_uid == getuid() else { return false }
        return info.st_mode & 0o077 == 0
    }
}
