import Foundation

/// In-process sidebar provider used by CMUX-owned sidebar presentations.
public protocol CmuxSidebarProvider: Sendable {
    /// Stable metadata describing the provider in selection UI.
    var descriptor: CmuxSidebarProviderDescriptor { get }
}
