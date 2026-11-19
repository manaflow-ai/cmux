public import Foundation

/// What a switch to another build the person started is doing (Settings > Updates' Channels card
/// shows it on the button they pressed): downloading, checking the download, checking the build
/// can open the stores, then restarting. Nil on ``UpdaterService/buildSwitchProgress`` when none runs.
nonisolated public struct BuildSwitchProgress: Equatable, Sendable {
    public enum Stage: String, Sendable, CaseIterable {
        case download, verify, stores, restart

        /// Steps run in this order: a switch never moves back one.
        var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    }

    /// The build being switched to (the newest kept one when the rollback named none: empty).
    public var build: String
    public var stage: Stage
    /// The downloaded fraction, 0...1, while the server sends a length; nil otherwise.
    public var fraction: Double?

    public init(build: String, stage: Stage, fraction: Double? = nil) {
        self.build = build
        self.stage = stage
        self.fraction = fraction
    }

    /// The Channels card's value (`cmux.settings.channels.switch.changed`).
    public var page: [String: Any] {
        ["build": build, "label": label, "fraction": fraction.map { min(1, max(0, $0)) as Any } ?? NSNull()]
    }

    /// What the button reads.
    public var label: String {
        switch stage {
        case .download:
            fraction.map { UpdaterStrings.switchDownloadingPercent(Int(($0 * 100).rounded(.down))) } ?? UpdaterStrings.switchDownloading
        case .verify: UpdaterStrings.switchVerifying
        case .stores: UpdaterStrings.switchCheckingStores
        case .restart: UpdaterStrings.switchRestarting
        }
    }
}

nonisolated extension UpdaterStrings {
    static var switchDownloading: String { text("updater.channels.progress.downloading", "Downloading…") }
    static func switchDownloadingPercent(_ percent: Int) -> String {
        format("updater.channels.progress.downloadingPercent", "Downloading… %@%%", String(percent))
    }
    static var switchVerifying: String { text("updater.channels.progress.verifying", "Checking the download…") }
    static var switchCheckingStores: String {
        text("updater.channels.progress.stores", "Checking it can open your sessions…")
    }
    static var switchRestarting: String { text("updater.channels.progress.restarting", "Restarting…") }
}
