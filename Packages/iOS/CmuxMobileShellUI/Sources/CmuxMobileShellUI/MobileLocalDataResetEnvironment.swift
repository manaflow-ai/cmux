import CmuxMobileShell
import SwiftUI

/// Starts the "erase all local data" reset owned by the app root.
///
/// The root runs the normal sign-out, erases local data through
/// ``MobileLocalDataEraser``, and replaces the UI with the reset screen, so the
/// Settings row only needs to trigger it.
public struct MobileResetLocalDataAction: Sendable {
    private let action: @MainActor @Sendable () -> Void

    public init(_ action: @escaping @MainActor @Sendable () -> Void) {
        self.action = action
    }

    @MainActor
    public func callAsFunction() {
        action()
    }
}

private struct MobileLocalDataEraserEnvironmentKey: EnvironmentKey {
    static let defaultValue: MobileLocalDataEraser? = nil
}

private struct MobileResetLocalDataEnvironmentKey: EnvironmentKey {
    static let defaultValue: MobileResetLocalDataAction? = nil
}

public extension EnvironmentValues {
    /// App-root eraser for this device's cmux data. Optional so previews and
    /// package-only hosts never erase a real container.
    var mobileLocalDataEraser: MobileLocalDataEraser? {
        get { self[MobileLocalDataEraserEnvironmentKey.self] }
        set { self[MobileLocalDataEraserEnvironmentKey.self] = newValue }
    }

    /// Set by the root view when an eraser is available; `nil` hides the
    /// Settings reset row.
    var mobileResetLocalData: MobileResetLocalDataAction? {
        get { self[MobileResetLocalDataEnvironmentKey.self] }
        set { self[MobileResetLocalDataEnvironmentKey.self] = newValue }
    }
}
