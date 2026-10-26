public import CmuxNextWakeups
public import Foundation
public import Observation
import os

/// The Labs page's writer of ``FeatureLocalOverrides``: what this launch
/// applied (``launch``) and what the next one will (``next``). Features are
/// resolved once per launch (no feature is runtime mutable), so a change
/// shows on the page at once and applies at the next start, as about:flags
/// asks to relaunch (chrome/browser/ui/webui/flags/flags_ui.cc). Only DEV and
/// NIGHTLY take local choices (``Feature/Channel/allowsLocalOverrides``).
@MainActor
@Observable
public final class FeatureLocalOverrideStore {
    /// Why a choice was refused.
    public enum Refusal: Error, Sendable, Equatable, CustomStringConvertible {
        /// This channel applies no local choice (Release).
        case channelTakesNoLocalChoices(Feature.Channel)
        /// The registry declares no feature by this name.
        case unknownFeature(String)

        public var description: String {
            switch self {
            case .channelTakesNoLocalChoices(let channel): "the \(channel.rawValue) channel takes no local feature choices"
            case .unknownFeature(let name): "no feature is named \(name)"
            }
        }
    }

    /// The choices this launch resolved its features with.
    public let launch: FeatureLocalOverrides
    /// The choices the next launch applies.
    public private(set) var next: FeatureLocalOverrides
    private let registry: FeatureRegistry
    private let channel: Feature.Channel
    private let file: URL?
    private let writes: WorkSequence
    private let report: @Sendable (String) -> Void

    nonisolated private static let logger = Logger(subsystem: "com.cmuxterm.app.next", category: "features")

    /// - Parameters:
    ///   - registry: the features a choice may name.
    ///   - channel: this build's channel.
    ///   - launch: what this launch read from `file` (an empty set where it read nothing).
    ///   - file: `<features folder>/local-overrides.json`; nil writes nothing (tests that build the App).
    ///   - work: the app's ``BackgroundWork``; writes run in order on its files lane.
    ///   - report: gets each failed write as a line, after the unified log has it; tests read it.
    public init(
        registry: FeatureRegistry,
        channel: Feature.Channel,
        launch: FeatureLocalOverrides,
        file: URL?,
        work: BackgroundWork,
        report: @escaping @Sendable (String) -> Void = { _ in }
    ) {
        self.registry = registry
        self.channel = channel
        self.launch = launch
        next = launch
        self.file = file
        writes = work.sequence("features.local-overrides")
        self.report = report
    }

    /// Sets `name` on or off for the next launch, or back to no choice with
    /// nil. The page shows it now; the file is written after, in order.
    public func set(_ name: String, _ value: Bool?) throws(Refusal) {
        guard channel.allowsLocalOverrides else { throw .channelTakesNoLocalChoices(channel) }
        guard registry.feature(named: name) != nil else { throw .unknownFeature(name) }
        let values = next.setting(name, to: value)
        guard values != next else { return }
        next = values
        guard let file else { return }
        let report = report
        writes.post(.userVisible, shutdown: .blockShutdown) {
            guard let failure = values.save(to: file) else { return }
            Self.logger.error("\(failure.description, privacy: .public)")
            report(failure.description)
        }
    }

    /// Returns once every write ``set(_:_:)`` posted before it has ended (the caller suspends; no thread waits).
    public func written() async {
        _ = try? await writes.run(.userVisible) {}
    }
}
