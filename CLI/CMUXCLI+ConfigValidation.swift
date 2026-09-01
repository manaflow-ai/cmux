import Foundation

extension CMUXCLI {
    func configDoctorDecodedFinding(
        target: ConfigDoctorTarget,
        dictionary: [String: Any],
        byteCount: Int
    ) -> ConfigDoctorFinding {
        let issues = CmuxConfigTypeValidator().issues(in: dictionary)
        return ConfigDoctorFinding(
            label: target.label,
            displayPath: target.displayPath,
            path: target.path,
            status: issues.isEmpty ? "ok" : "error",
            message: issues.isEmpty ? "JSONC syntax is valid" : issues.map(\.description).joined(separator: "; "),
            keys: dictionary.keys.sorted(),
            byteCount: byteCount
        )
    }
}
