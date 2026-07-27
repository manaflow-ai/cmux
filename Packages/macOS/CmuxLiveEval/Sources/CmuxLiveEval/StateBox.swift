import CmuxSwiftRender
import Observation

/// One observable storage box backing a single interpreted `@State`
/// declaration.
///
/// This is the heart of the live-eval state mechanism: the box is a real
/// `@Observable` class, so any SwiftUI `body` (including a compiled stub view
/// whose body re-walks an interpreted AST) that reads ``value`` registers an
/// Observation dependency on exactly this box. Mutating ``value`` from a
/// Button action or a Binding setter then invalidates only the views that
/// actually read it.
/// `@unchecked Sendable`: Observation's registrar is thread-safe and box
/// values are read/written on the main actor by convention (the engine and
/// every SwiftUI entry point are MainActor). Sendable is needed because real
/// `Binding` get/set closures are `@Sendable` and capture the box.
@Observable
public final class StateBox: @unchecked Sendable {
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
/// One store is created per `InterpretedView` identity (held in compiled
/// `@State`, so SwiftUI owns its lifetime) and seeded from the `@State`
/// declarations in the interpreted source. The dictionary itself is
/// immutable; only box values change.
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
