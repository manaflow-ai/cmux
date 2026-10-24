import CmuxNextControl

// The app's wiring of session transfer, named where AppServices.swift and AppControl.swift
// already call it. These forwards go when those two lines name ``AppSessionTransferHost``
// and ``SessionTransferControl/methods(transfer:)`` themselves.

extension SessionTransferService {
    /// The app's service: ``AppSessionTransferHost`` over `services`, peers from the control socket paths.
    convenience init(services: AppServices) {
        self.init(host: AppSessionTransferHost(services: services),
                  peerSocketPaths: { ControlSocketPath.shared.peerSocketPaths() })
    }
}

extension SessionTransferControl {
    /// The control methods of the app's ``SessionTransferService``.
    static func methods(services: AppServices) -> [ControlMethod] {
        methods(transfer: services.sessionTransfer)
    }
}
