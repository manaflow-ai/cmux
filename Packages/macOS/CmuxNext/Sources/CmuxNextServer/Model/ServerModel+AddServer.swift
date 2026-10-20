import Foundation

/// The Add Server sheet's state flow and keys (red stub: the tests in AddServerFlowTests fail).
extension ServerModel {
    public var addServerStep: AddServerStep { .enterCode }

    public var addServerButtons: [AddServerButton] { [] }

    @discardableResult
    public func perform(_ action: AddServerAction) -> Bool { false }

    public func beginApproval() {}
}
