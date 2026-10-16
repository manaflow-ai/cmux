import Foundation

extension GhosttyApp {
    /// Returns the formatted diagnostics Ghostty collected while loading
    /// `config` (`<path>:<line>:<key>: <message>` for file diagnostics).
    static func configDiagnosticMessages(_ config: ghostty_config_t) -> [String] {
        let count = Int(ghostty_config_diagnostics_count(config))
        guard count > 0 else { return [] }
        return (0..<count).compactMap { index in
            let diagnostic = ghostty_config_get_diagnostic(config, UInt32(index))
            guard let message = diagnostic.message else { return nil }
            return String(cString: message)
        }
    }
}
