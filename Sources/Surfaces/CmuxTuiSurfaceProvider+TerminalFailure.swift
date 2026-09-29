import CmuxCloud

extension CmuxTuiSurfaceProvider {
    /// Records a conclusively missing machine once and lets the registry retire
    /// its local bindings. Every other VM failure keeps the existing retry path.
    func reportMissingCloudMachine(_ error: Error) -> Bool {
        guard let cloudError = (error as? VMClientError)?.cloudHTTPError,
              cloudError.isMachineNotFound else { return false }
        onMachineNotFound?(machineID, cloudError)
        return true
    }
}
