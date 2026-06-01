import Foundation

public protocol CmuxSidebarProvider: Sendable {
    var descriptor: CmuxSidebarProviderDescriptor { get }
}
