import CMUXMobileCore
import Foundation

enum HivePairingInput: Equatable, Sendable {
    case link(String)
    case manual(CmxManualPairingEntry)

    init?(_ rawValue: String) {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if CmxPairingURLScheme(urlString: value) != nil {
            self = .link(value)
            return
        }
        guard !value.contains("://"),
              let components = URLComponents(string: "tcp://" + value),
              components.user == nil, components.password == nil,
              components.path.isEmpty, components.query == nil, components.fragment == nil,
              let host = components.host, !host.isEmpty,
              let port = components.port, (1...65535).contains(port) else { return nil }
        let normalizedHost = host.hasPrefix("[") && host.hasSuffix("]")
            ? String(host.dropFirst().dropLast()) : host
        self = .manual(CmxManualPairingEntry(host: normalizedHost, port: port))
    }
}
