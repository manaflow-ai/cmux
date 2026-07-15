struct ChromiumViewportInputCommand: Equatable {
    let method: String
    var parameters: [String: CDPJSONValue]
    let coalescingKind: ChromiumViewportInputCoalescingKind?

    var gestureTransition: ChromiumViewportGestureTransition? {
        switch (method, parameters["type"], parameters["code"], parameters["button"]) {
        case ("Input.dispatchKeyEvent", .string("keyDown"), .string(let code), _):
            return .began("key:\(code)")
        case ("Input.dispatchKeyEvent", .string("keyUp"), .string(let code), _):
            return .ended("key:\(code)")
        case ("Input.dispatchMouseEvent", .string("mousePressed"), _, .string(let button)):
            return .began("mouse:\(button)")
        case ("Input.dispatchMouseEvent", .string("mouseReleased"), _, .string(let button)):
            return .ended("mouse:\(button)")
        default:
            return nil
        }
    }

    private init(
        method: String,
        parameters: [String: CDPJSONValue],
        coalescingKind: ChromiumViewportInputCoalescingKind?
    ) {
        self.method = method
        self.parameters = parameters
        self.coalescingKind = coalescingKind
    }

    init(mouseParameters parameters: [String: CDPJSONValue]) {
        let coalescingKind: ChromiumViewportInputCoalescingKind? = switch parameters["type"] {
        case .string("mouseMoved"):
            .mouseMove
        case .string("mouseWheel"):
            .mouseWheel
        default:
            nil
        }
        self.init(
            method: "Input.dispatchMouseEvent",
            parameters: parameters,
            coalescingKind: coalescingKind
        )
    }

    init(keyParameters parameters: [String: CDPJSONValue]) {
        self.init(
            method: "Input.dispatchKeyEvent",
            parameters: parameters,
            coalescingKind: nil
        )
    }

    init(textParameters parameters: [String: CDPJSONValue]) {
        self.init(
            method: "Input.insertText",
            parameters: parameters,
            coalescingKind: nil
        )
    }

    init(compositionParameters parameters: [String: CDPJSONValue]) {
        self.init(
            method: "Input.imeSetComposition",
            parameters: parameters,
            coalescingKind: nil
        )
    }

    func coalescing(with newer: Self) -> Self {
        guard coalescingKind == .mouseWheel, newer.coalescingKind == .mouseWheel else {
            return newer
        }
        var parameters = newer.parameters
        parameters["deltaX"] = .number(number(for: "deltaX") + newer.number(for: "deltaX"))
        parameters["deltaY"] = .number(number(for: "deltaY") + newer.number(for: "deltaY"))
        return Self(
            method: newer.method,
            parameters: parameters,
            coalescingKind: newer.coalescingKind
        )
    }

    private func number(for key: String) -> Double {
        guard case .number(let value) = parameters[key] else { return 0 }
        return value
    }
}
