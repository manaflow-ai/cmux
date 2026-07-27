import AppKit
import CmuxSimulator
import Foundation

struct ApplicationWindowDescriptor: Identifiable, Equatable, Sendable {
    var id: UInt32 { windowID }

    let windowID: UInt32
    let processID: Int32
    let owner: String
    let title: String
    let width: Double
    let height: Double
}

struct ApplicationSurfaceSessionDescriptor: Equatable, Sendable {
    let sessionID: String
    let frameTransport: SimulatorFrameTransportDescriptor
}

struct ApplicationSurfaceInputEvent: Equatable, Sendable {
    enum Kind: String, Sendable {
        case mouseMoved = "mouse_moved"
        case leftMouseDown = "left_mouse_down"
        case leftMouseUp = "left_mouse_up"
        case leftMouseDragged = "left_mouse_dragged"
        case rightMouseDown = "right_mouse_down"
        case rightMouseUp = "right_mouse_up"
        case rightMouseDragged = "right_mouse_dragged"
        case scroll
        case key

        var isCoalescibleMotion: Bool {
            self == .mouseMoved || self == .leftMouseDragged || self == .rightMouseDragged
        }
    }

    let kind: Kind
    var x: Double = 0
    var y: Double = 0
    var keyCode: UInt16 = 0
    var keyDown: Bool = false
    var modifiers: UInt64 = 0
    var clickCount: Int = 1
    var deltaX: Double = 0
    var deltaY: Double = 0
}

enum ApplicationSurfaceRuntimeError: LocalizedError, Equatable {
    case permissionRequired
    case windowUnavailable
    case helperUnavailable
    case pointOutsideContent
    case invalidResponse
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .permissionRequired:
            String(
                localized: "applicationSurface.error.permissionRequired",
                defaultValue: "Application panes need Accessibility and Screen Recording access."
            )
        case .windowUnavailable:
            String(
                localized: "applicationSurface.error.windowUnavailable",
                defaultValue: "The selected application window is no longer available."
            )
        case .helperUnavailable:
            String(
                localized: "applicationSurface.error.helperUnavailable",
                defaultValue: "The cmux Computer Use helper is unavailable."
            )
        case .pointOutsideContent:
            nil
        case .invalidResponse:
            String(
                localized: "applicationSurface.error.invalidResponse",
                defaultValue: "The cmux Computer Use helper returned an invalid response."
            )
        case .failed(let detail):
            detail
        }
    }
}

@MainActor
final class ApplicationSurfaceRuntimeLease {
    weak var service: ComputerUseRuntimeService?
    let identifier: UUID
    private var isReleased = false

    init(service: ComputerUseRuntimeService, identifier: UUID) {
        self.service = service
        self.identifier = identifier
    }

    func release() {
        guard !isReleased else { return }
        isReleased = true
        let service = service
        self.service = nil
        Task { @MainActor in
            await service?.releaseApplicationSurfaceLease(identifier)
        }
    }

    deinit {
        guard !isReleased, let service else { return }
        let identifier = identifier
        Task { @MainActor in
            await service.releaseApplicationSurfaceLease(identifier)
        }
    }
}

@MainActor
protocol ApplicationSurfaceRuntime: AnyObject {
    func acquireApplicationSurfaceLease() async -> ApplicationSurfaceRuntimeLease?
    func listApplicationWindows(
        lease: ApplicationSurfaceRuntimeLease
    ) async throws -> [ApplicationWindowDescriptor]
    func startApplicationSurface(
        lease: ApplicationSurfaceRuntimeLease,
        windowID: UInt32,
        processID: Int32,
        frameRate: Int
    ) async throws -> ApplicationSurfaceSessionDescriptor
    func stopApplicationSurface(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String
    ) async
    func sendApplicationSurfaceEvent(
        lease: ApplicationSurfaceRuntimeLease,
        sessionID: String,
        event: ApplicationSurfaceInputEvent
    ) async throws
}
