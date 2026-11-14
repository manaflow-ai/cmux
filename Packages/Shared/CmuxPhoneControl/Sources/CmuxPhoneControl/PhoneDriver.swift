import Foundation

public protocol PhoneDriver: Sendable {
    func device() async throws -> PhoneDevice
    func snapshot() async throws -> PhoneScreenFrame
    func accessibilityTree() async throws -> PhoneUIElement?
    func perform(_ action: PhoneActionRequest) async throws -> PhoneActionReceipt
}

public enum PhoneDriverError: Error, Equatable, Sendable {
    case unsupported(String)
    case unavailable(String)
    case transport(String)
    case malformedResponse(String)
}

/// A deterministic source for protocol tests and local client development.
/// It intentionally behaves like a device: each accepted action advances the
/// frame sequence, and duplicate action IDs return the original receipt.
public actor MockPhoneDriver: PhoneDriver {
    private var currentFrame: PhoneScreenFrame
    private var receipts: [String: PhoneActionReceipt] = [:]
    private let deviceValue: PhoneDevice

    public init(
        deviceID: String = "mock-iphone",
        width: Int = 390,
        height: Int = 844,
        frameData: Data = Data("cmux-phone-mock-frame".utf8)
    ) {
        let geometry = PhoneDisplayGeometry(width: width, height: height, scale: 3)
        let capabilities = PhoneCapabilities(
            screenSnapshot: true,
            screenStream: false,
            accessibilityTree: true,
            tap: true,
            swipe: true,
            typing: true,
            physicalButtons: true
        )
        deviceValue = PhoneDevice(
            id: deviceID,
            name: "Mock iPhone",
            model: "iPhone (mock)",
            osVersion: "18.0",
            source: .mock,
            state: .available,
            geometry: geometry,
            capabilities: capabilities
        )
        currentFrame = PhoneScreenFrame(
            sequence: 1,
            width: width,
            height: height,
            orientation: geometry.orientation,
            data: frameData
        )
    }

    public func device() async throws -> PhoneDevice { deviceValue }

    public func snapshot() async throws -> PhoneScreenFrame { currentFrame }

    public func accessibilityTree() async throws -> PhoneUIElement? {
        PhoneUIElement(
            id: "root",
            role: "window",
            label: "Mock iPhone",
            bounds: .init(
                x: 0,
                y: 0,
                width: 1,
                height: 1
            ),
            actions: ["tap"],
            children: [
                PhoneUIElement(
                    id: "primary-button",
                    role: "button",
                    label: "Continue",
                    bounds: .init(x: 0.1, y: 0.4, width: 0.8, height: 0.08),
                    actions: ["tap"]
                )
            ]
        )
    }

    public func perform(_ action: PhoneActionRequest) async throws -> PhoneActionReceipt {
        if let previous = receipts[action.actionID] {
            return PhoneActionReceipt(
                actionID: previous.actionID,
                accepted: previous.accepted,
                duplicate: true,
                screenSequence: previous.screenSequence,
                detail: previous.detail
            )
        }
        try action.validated()
        switch action.kind {
        case .tap, .longPress:
            guard let point = action.point else {
                throw PhoneError(code: "invalid_action", message: "action requires a point")
            }
            try point.validated()
        case .swipe:
            guard let point = action.point, let endPoint = action.endPoint else {
                throw PhoneError(code: "invalid_action", message: "swipe requires point and end_point")
            }
            try point.validated()
            try endPoint.validated()
        case .type:
            guard let text = action.text, !text.isEmpty else {
                throw PhoneError(code: "invalid_action", message: "text action requires non-empty text")
            }
        case .press:
            guard let button = action.button, !button.isEmpty else {
                throw PhoneError(code: "invalid_action", message: "press requires button")
            }
        }
        currentFrame = PhoneScreenFrame(
            sequence: currentFrame.sequence + 1,
            width: currentFrame.width,
            height: currentFrame.height,
            orientation: currentFrame.orientation,
            data: Data("mock-frame-\(currentFrame.sequence + 1)-\(action.kind.rawValue)".utf8)
        )
        let receipt = PhoneActionReceipt(
            actionID: action.actionID,
            accepted: true,
            screenSequence: currentFrame.sequence,
            detail: "mock action applied"
        )
        receipts[action.actionID] = receipt
        return receipt
    }
}
