import Foundation

extension CMUXCLI {
    func configDoctorDecodedFinding(
        target: ConfigDoctorTarget,
        dictionary: [String: Any],
        byteCount: Int
    ) -> ConfigDoctorFinding {
        let issues = CmuxConfigTypeValidator(
            workspaceColorNames: CmuxConfigTypeValidator.workspaceColorNames(from: .standard)
        ).issues(in: dictionary)
        return ConfigDoctorFinding(
            label: target.label,
            displayPath: target.displayPath,
            path: target.path,
            status: issues.isEmpty ? "ok" : "error",
            message: issues.isEmpty
                ? String(
                    localized: "config.doctor.valid",
                    defaultValue: "JSONC syntax and configuration entries are valid"
                )
                : issues.map(\.description).joined(separator: "; "),
            keys: dictionary.keys.sorted(),
            byteCount: byteCount
        )
    }
}
