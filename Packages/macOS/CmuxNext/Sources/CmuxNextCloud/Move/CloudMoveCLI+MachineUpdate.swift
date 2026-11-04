extension CloudMoveCLI.Answer {
    /// `link machine update`: whether the machine's daemon may have restarted in the run that gave
    /// this answer: an update, a rollback, or an end the CLI lost track of. Not for a machine that
    /// needed nothing, nor for an answer given before anything reached it (another update runs, no
    /// daemon answer, no build to install, too old to update in place, a daemon on someone's own
    /// build from another path).
    public var mayHaveRestartedDaemon: Bool {
        if ok { return updated }
        switch errorCode {
        case "machine_update_busy", "machine_unreachable", "machine_update_unavailable", "machine_update_download_failed",
             "machine_update_unsupported", "machine_update_foreign_daemon":
            return false
        default:
            return true
        }
    }
}
