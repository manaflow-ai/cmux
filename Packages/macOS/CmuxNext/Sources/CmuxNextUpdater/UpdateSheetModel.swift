public import AppKit
import CmuxUpdater
import Observation

/// What the update sheet renders and where its buttons go.
@MainActor
public protocol UpdateSheetSource: AnyObject, Observable {
    /// Nil closes the sheet.
    var content: UpdateSheetContent? { get }
    func perform(_ button: UpdateSheetButton)
}

/// The live source: Sparkle's phase when Sparkle runs, else the probe.
@MainActor
@Observable
public final class UpdateSheetModel: UpdateSheetSource {
    @ObservationIgnored public let service: UpdaterService

    public init(service: UpdaterService) {
        self.service = service
    }

    public var content: UpdateSheetContent? {
        if let controller = service.controller, service.disabledReason == nil {
            let content = UpdateSheetContent.sparkle(controller.model.effectiveState, current: service.identity)
            return service.requiredMinimumVersion.map { content?.requiring($0) } ?? content
        }
        return UpdateSheetContent.probe(result: service.lastProbe, error: service.lastProbeError,
                                        probing: service.isProbing, disabledReason: service.disabledReason)
    }

    public func perform(_ button: UpdateSheetButton) {
        let state = service.controller?.model.effectiveState
        switch button {
        case .install:
            try? service.installAvailableUpdate()
        case .later, .cancel, .done:
            state?.cancel()
        case .retry:
            state?.cancel()
            service.checkForUpdates()
        case .relaunch:
            if case .installing(let installing) = state { installing.retryTerminatingApplication() }
        case .releaseNotes(let url):
            NSWorkspace.shared.open(url)
        }
    }
}

/// A fixed sheet for demos and screenshots.
@MainActor
@Observable
public final class StaticUpdateSheetSource: UpdateSheetSource {
    public var content: UpdateSheetContent?
    public private(set) var pressed: [UpdateSheetButton] = []

    public init(_ content: UpdateSheetContent?) {
        self.content = content
    }

    public func perform(_ button: UpdateSheetButton) {
        pressed.append(button)
    }
}
