import CmuxSwiftRender
import Observation

/// One observable storage box backing a single interpreted `@State`
/// declaration.
///
/// A native view that reads ``value`` inside Observation tracking registers a
/// dependency on exactly this box. Mutating it then invalidates only views
/// that actually read it.
@Observable
@MainActor
public final class StateBox {
    /// The declared `@State` name (without the `@State` / `$` decoration).
    public let name: String

    /// The current value. Reads register an Observation dependency; writes
    /// trigger invalidation of every registered reader.
    public var value: SwiftValue

    public init(name: String, value: SwiftValue) {
        self.name = name
        self.value = value
    }
}

/// All ``StateBox``es for one interpreted view instance.
///
/// One store is created per ``InterpretedView`` instance and seeded from the
/// state declarations in interpreted source. The dictionary is immutable;
/// only box values change.
@MainActor
public final class LiveStateStore {
    private let boxes: [String: StateBox]

    public init(declarations: [LiveStateDeclaration]) {
        var boxes: [String: StateBox] = [:]
        for declaration in declarations {
            boxes[declaration.name] = StateBox(name: declaration.name, value: declaration.initialValue)
        }
        self.boxes = boxes
    }

    /// The box backing `name`, or nil when the source declared no such state.
    public func box(_ name: String) -> StateBox? {
        boxes[name]
    }

    /// Declared state names (sorted, for diagnostics).
    public var names: [String] {
        boxes.keys.sorted()
    }
}

/// One `@State var name = initial` declaration extracted from interpreted
/// source.
public struct LiveStateDeclaration: Sendable {
    public let name: String
    public let initialValue: SwiftValue

    public init(name: String, initialValue: SwiftValue) {
        self.name = name
        self.initialValue = initialValue
    }
}
