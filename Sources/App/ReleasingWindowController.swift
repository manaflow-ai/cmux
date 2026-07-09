import CmuxAppKitSupportUI

/// App-target spelling for the managed-window base class, which now lives in
/// `CmuxAppKitSupportUI`. Every debug/lab/feed window controller subclasses this
/// name; the typealias keeps that spelling byte-identical after the lift.
typealias ReleasingWindowController = CmuxAppKitSupportUI.ReleasingWindowController
