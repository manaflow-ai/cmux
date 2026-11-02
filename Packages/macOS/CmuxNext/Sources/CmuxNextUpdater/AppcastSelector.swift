/// Picks what a feed offers, as Sparkle decides it, with the update rules (cmux-updater-core):
/// Sparkle's own version order (`SUStandardVersionComparator`, ported) and its OS filter, so an
/// item is offered only when `minimumSystemVersion <= macOS <= maximumSystemVersion`, and the
/// newest offered item wins.
nonisolated public enum AppcastSelector {
    public static func select(from items: [AppcastItem], currentBuild: String, system: SystemVersion) -> UpdateProbeOutcome {
        let request = SelectRequest(items: items.map(AppcastItem.Wire.init), currentBuild: currentBuild, system: system)
        guard let answer: SelectAnswer = UpdaterRules().call("updater_appcast_select", json: request) else {
            return .upToDate(latest: nil)
        }
        let item = answer.item.flatMap { items.indices.contains($0) ? items[$0] : nil }
        switch answer.kind {
        case "update_available":
            if let item { return .updateAvailable(item) }
        case "requires_newer_macos":
            if let item { return .requiresNewerSystem(item, required: answer.required ?? system) }
        default:
            break
        }
        return .upToDate(latest: answer.latest.flatMap { items.indices.contains($0) ? items[$0] : nil })
    }

    /// Sparkle's ordering of `CFBundleVersion` strings: `lhs` is older than `rhs`.
    public static func isOlder(_ lhs: String, than rhs: String) -> Bool {
        let answer: CompareAnswer? = UpdaterRules().call("updater_version_compare", json: CompareRequest(lhs: lhs, rhs: rhs))
        return answer?.order == -1
    }
}

nonisolated private struct SelectRequest: Encodable {
    var items: [AppcastItem.Wire]
    var currentBuild: String
    var system: SystemVersion
}

nonisolated private struct SelectAnswer: Decodable {
    var kind: String
    var item: Int?
    var latest: Int?
    var required: SystemVersion?
}

nonisolated private struct CompareRequest: Encodable {
    var lhs: String
    var rhs: String
}

nonisolated private struct CompareAnswer: Decodable {
    var order: Int
}
