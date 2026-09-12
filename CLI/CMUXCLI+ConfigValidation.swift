import Foundation

extension CMUXCLI {
    func configDoctorDecodedFinding(
        target: ConfigDoctorTarget,
        dictionary: [String: Any],
        byteCount: Int
    ) -> ConfigDoctorFinding {
        let issues = CmuxConfigTypeValidator(
            workspaceColorNames: CmuxConfigTypeValidator.workspaceColorNames(from: configDoctorAppDefaults())
        ).issues(in: dictionary)
        return ConfigDoctorFinding(
            label: target.label,
            displayPath: target.displayPath,
            path: target.path,
            status: issues.isEmpty ? "ok" : "error",
            message: issues.isEmpty
                ? String(
                    localized: "config.doctor.valid",
                    defaultValue: "JSONC syntax and command entries are valid"
                )
                : issues.map(\.description).joined(separator: "; "),
            keys: dictionary.keys.sorted(),
            byteCount: byteCount
        )
    }
}

private extension CMUXCLI {
    func configDoctorAppDefaults() -> UserDefaults {
        let environment = ProcessInfo.processInfo.environment
        let bundleIdentifier: String?
        if let rawBundleIdentifier = environment["CMUX_BUNDLE_ID"] {
            let trimmed = rawBundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
            bundleIdentifier = trimmed.isEmpty ? nil : trimmed
        } else {
            bundleIdentifier = CLISocketPathResolver.currentAppBundleIdentifier()
        }
        return bundleIdentifier.flatMap { UserDefaults(suiteName: $0) } ?? .standard
    }
}
