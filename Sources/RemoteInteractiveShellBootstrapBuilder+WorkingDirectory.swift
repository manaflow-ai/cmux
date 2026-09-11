extension RemoteInteractiveShellBootstrapBuilder {
    static func remoteInitialWorkingDirectoryLines() -> [String] {
        [
            "cmux_remote_initial_cwd_b64='__CMUX_REMOTE_INITIAL_CWD_B64__'",
            "if [ \"$cmux_remote_initial_cwd_b64\" = '__CMUX_''REMOTE_INITIAL_CWD_B64__' ]; then cmux_remote_initial_cwd_b64=''; fi",
            "if [ -n \"$cmux_remote_initial_cwd_b64\" ]; then",
            "  cmux_remote_initial_cwd=\"$(printf %s \"$cmux_remote_initial_cwd_b64\" | base64 -d 2>/dev/null || printf %s \"$cmux_remote_initial_cwd_b64\" | base64 -D 2>/dev/null || true)\"",
            "  if [ -n \"$cmux_remote_initial_cwd\" ]; then cd \"$cmux_remote_initial_cwd\" 2>/dev/null || true; fi",
            "fi",
            "unset cmux_remote_initial_cwd_b64 cmux_remote_initial_cwd",
        ]
    }
}
