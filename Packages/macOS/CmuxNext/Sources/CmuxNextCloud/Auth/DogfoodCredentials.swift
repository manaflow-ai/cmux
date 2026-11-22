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
/// (uitest keys). Ambient files sign in only the machine's declared owner
/// account (`~/.config/cmux/dev-account` or `CMUX_DEV_AUTH_ACCOUNT`).
struct DogfoodCredentials: Equatable {
    let email: String
    let password: String

    /// Why a tagged build starts signed out (logged, never the secret).
    enum Refusal: Equatable {
        case noDeclaredAccount
        case accountMismatch(found: String, declared: String)
    }

    static func resolve(environment: [String: String], home: String,
                        read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) }) -> DogfoodCredentials? {
        decide(environment: environment, home: home, read: read).credentials
    }

    /// The account to sign in, or why none. An explicit credentials file
    /// (`CMUX_AUTH_CREDENTIALS_FILE`) is taken as given, unless
    /// `CMUX_DEV_AUTH_ACCOUNT` names another account. The ambient files
    /// (`~/.secrets/cmuxterm-dev.env`, `~/.secrets/cmux.env`) and exports
    /// sign in only the machine's declared owner account
    /// (`CMUX_DEV_AUTH_ACCOUNT`, else `~/.config/cmux/dev-account`): a
    /// machine's secrets file can name another person (hmdm1 on
    /// cmux-lawrence-2, 2026-10-06).
    static func decide(environment: [String: String], home: String,
                       read: (String) -> String? = { try? String(contentsOfFile: $0, encoding: .utf8) })
        -> (credentials: DogfoodCredentials?, refusal: Refusal?) {
        let expected = environment["CMUX_DEV_AUTH_ACCOUNT"].flatMap { $0.isEmpty ? nil : $0 }
        if let explicit = environment["CMUX_AUTH_CREDENTIALS_FILE"], !explicit.isEmpty {
            guard secure(explicit), let text = read(explicit) else { return (nil, nil) }
            let values = parse(text)
            guard let found = pair(values, prefix: "CMUX_DOGFOOD_STACK") ?? pair(values, prefix: "CMUX_UITEST_STACK") else { return (nil, nil) }
            if let expected, found.email.lowercased() != expected.lowercased() {
                return (nil, .accountMismatch(found: found.email, declared: expected))
            }
            return (found, nil)
        }
        guard let declared = expected ?? declaredAccount(home: home, read: read) else { return (nil, .noDeclaredAccount) }
        let prefixes: [String] = switch environment["CMUX_DEV_AUTH_PROFILE"]?.lowercased() {
        case nil, "": ["CMUX_DOGFOOD_STACK", "CMUX_UITEST_STACK"]
        case "personal": ["CMUX_DOGFOOD_STACK"]
        case "agent": ["CMUX_UITEST_STACK"]
        default: []
        }
        let files = ["\(home)/.secrets/cmuxterm-dev.env", "\(home)/.secrets/cmux.env"].compactMap(read).map(parse)
        var first: DogfoodCredentials?
        for prefix in prefixes {
            for found in (files + [environment]).compactMap({ pair($0, prefix: prefix) }) {
                if found.email.lowercased() == declared.lowercased() { return (found, nil) }
                first = first ?? found
            }
        }
        return (nil, first.map { .accountMismatch(found: $0.email, declared: declared) })
    }

    /// The machine owner's account (`~/.config/cmux/dev-account`, one email; not a secret).
    static func declaredAccount(home: String, read: (String) -> String?) -> String? {
        guard let text = read("\(home)/.config/cmux/dev-account") else { return nil }
        let email = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return email.isEmpty ? nil : email
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
