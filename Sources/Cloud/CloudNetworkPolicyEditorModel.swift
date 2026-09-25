import Foundation
import Observation

/// Editable state behind ``CloudNetworkPolicyEditor``, shared by the New
/// Machine sheet and the Network sheet. Every change goes through
/// ``CloudNetworkPolicy/apply(_:knownPresetIDs:)``, the same rules
/// `cmux vm network` uses, and a refused change becomes ``inputError``.
@MainActor
@Observable
final class CloudNetworkPolicyEditorModel {
    private(set) var policy: CloudNetworkPolicy
    private(set) var catalog: CloudNetworkPresetCatalog?

    /// Text fields for the next entry. Cleared once the entry is added.
    var domainDraft = ""
    var rangeDraft = ""
    var portDraft = ""
    var protocolDraft: CloudNetworkRangeProtocol = .tcp

    /// Why the last add or toggle was refused; cleared by the next success.
    private(set) var inputError: String?

    init(policy: CloudNetworkPolicy = .default, catalog: CloudNetworkPresetCatalog? = nil) {
        self.policy = policy
        self.catalog = catalog
    }

    var mode: CloudNetworkPolicyMode {
        get { policy.mode }
        set { perform(.setMode(newValue)) }
    }

    var allowDns: Bool {
        get { policy.allowDns }
        set { perform(.setAllowDns(newValue)) }
    }

    var showsAllowlistDetails: Bool { policy.mode == .allowlist }
    var presets: [CloudNetworkPreset] { catalog?.presets ?? [] }
    var requiredDomains: [String] { catalog?.requiredDomains ?? [] }

    /// "Includes files.cmux.com, github.com, … which cmux needs." for the
    /// restrictive modes; nil in Full mode or before the catalog loads.
    var requiredDomainsNote: String? {
        guard policy.mode != .full, !requiredDomains.isEmpty else { return nil }
        let format = String(localized: "cloud.network.required.note", defaultValue: "Always allowed so cmux keeps working: %@.")
        return String(format: format, ListFormatter.localizedString(byJoining: requiredDomains))
    }

    func isPresetEnabled(_ id: String) -> Bool { policy.presets.contains(id) }

    func setPreset(_ id: String, enabled: Bool) {
        perform(.setPreset(id, enabled: enabled))
    }

    func addDomain() {
        guard !domainDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        if perform(.addDomain(domainDraft)) { domainDraft = "" }
    }

    func removeDomain(_ domain: String) {
        perform(.removeDomain(domain))
    }

    func addRange() {
        let cidr = rangeDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cidr.isEmpty else { return }
        let portText = portDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        var port: Int?
        if !portText.isEmpty {
            guard let parsed = Int(portText) else {
                inputError = CloudNetworkPolicyEditError.invalidPort.errorDescription
                return
            }
            port = parsed
        }
        let range = CloudNetworkRange(cidr: cidr, port: port, transport: port == nil ? nil : protocolDraft)
        if perform(.addRange(range)) {
            rangeDraft = ""
            portDraft = ""
        }
    }

    func removeRange(_ range: CloudNetworkRange) {
        perform(.removeRange(range))
    }

    /// Replaces everything with a server answer (load or save response).
    func load(policy: CloudNetworkPolicy, catalog: CloudNetworkPresetCatalog?) {
        self.policy = policy
        if let catalog { self.catalog = catalog }
        inputError = nil
    }

    func setCatalog(_ catalog: CloudNetworkPresetCatalog) {
        self.catalog = catalog
    }

    @discardableResult
    private func perform(_ edit: CloudNetworkPolicyEdit) -> Bool {
        var next = policy
        do {
            let known = catalog.map { Set($0.presets.map(\.id)) }
            try next.apply(edit, knownPresetIDs: known)
        } catch {
            inputError = (error as? LocalizedError)?.errorDescription ?? String(describing: error)
            return false
        }
        policy = next
        inputError = nil
        return true
    }
}
