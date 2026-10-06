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
/// (uitest keys); without a profile or a credentials file nothing signs in.
/// `CMUX_DEV_AUTH_ACCOUNT`, when set, is the only email that may sign in.
struct DogfoodCredentials: Equatable {
    let email: String
    let password: String

    /// Why a tagged build starts signed out (logged, never the secret).
    enum Refusal: Equatable {
        case noDeclaredAccount
        case accountMismatch(found: String, declared: String)
    }

    /// Red stub.
    static func decide(environment: [String: String], home: String,
                       read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) })
        -> (credentials: DogfoodCredentials?, refusal: Refusal?) {
        (resolve(environment: environment, home: home, read: read), nil)
    }

    static func resolve(environment: [String: String], home: String,
                        read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> DogfoodCredentials? {
        guard let found = candidate(environment: environment, home: home, read: read) else { return nil }
        // The launcher's expected account (CMUX_DEV_AUTH_ACCOUNT): any other
        // account signs in nobody, whichever file or export named it.
        if let expected = environment["CMUX_DEV_AUTH_ACCOUNT"], !expected.isEmpty,
           found.email.lowercased() != expected.lowercased() { return nil }
        return found
    }

    /// The pair an explicit credentials file or an explicit profile names.
    /// Without either, nobody: a machine's ambient secrets file can name
    /// another person (hmdm1 on cmux-lawrence-2, 2026-10-06).
    private static func candidate(environment: [String: String], home: String, read: (String) -> String?) -> DogfoodCredentials? {
        if let explicit = environment["CMUX_AUTH_CREDENTIALS_FILE"], !explicit.isEmpty {
            guard secure(explicit), let text = read(explicit) else { return nil }
            let values = parse(text)
            return pair(values, prefix: "CMUX_DOGFOOD_STACK") ?? pair(values, prefix: "CMUX_UITEST_STACK")
        }
        let prefix: String
        switch environment["CMUX_DEV_AUTH_PROFILE"]?.lowercased() {
        case "personal": prefix = "CMUX_DOGFOOD_STACK"
        case "agent": prefix = "CMUX_UITEST_STACK"
        default: return nil
        }
        let files = ["\(home)/.secrets/cmuxterm-dev.env", "\(home)/.secrets/cmux.env"].compactMap(read).map(parse)
        for values in files { if let found = pair(values, prefix: prefix) { return found } }
        return pair(environment, prefix: prefix)
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
