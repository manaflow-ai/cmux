public import Foundation

/// The home an app reopened by `/usr/bin/open` keeps. LaunchServices starts the app with the
/// login session's environment, not the caller's, so an app running in a throwaway home (a CI
/// drill sets `HOME` and `CFFIXED_USER_HOME`) would come back after an update or a rollback in
/// the account's real home and write that account's cmux folders. Only then does the reopen
/// pass the home on with `open --env`; a launch in the account's own home passes nothing, so its
/// `open` argv is what it always was.
nonisolated public enum RelaunchHome {
    /// The variables that pick the app's home.
    public static let variables = ["HOME", "CFFIXED_USER_HOME"]

    /// `open` options (`--env NAME=VALUE` pairs) that keep the running app's home, or none when
    /// `HOME` is the account's home and `CFFIXED_USER_HOME` is unset. Callers pass them as
    /// positional shell arguments (`"$@"`), never inside the script text.
    public static func openArguments(environment: [String: String] = ProcessInfo.processInfo.environment,
                                     accountHome: String? = RelaunchHome.accountHome()) -> [String] {
        let home = environment["HOME"]
        guard environment["CFFIXED_USER_HOME"] != nil || (home != nil && home != accountHome) else { return [] }
        return variables.flatMap { name in environment[name].map { ["--env", "\(name)=\($0)"] } ?? [] }
    }

    /// The account's home directory from the user database, which no environment variable changes.
    public static func accountHome() -> String? {
        guard let entry = getpwuid(getuid()), let directory = entry.pointee.pw_dir else { return nil }
        return String(cString: directory)
    }
}
