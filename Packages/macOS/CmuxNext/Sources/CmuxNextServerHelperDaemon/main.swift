import CmuxNextServerHelper
import Foundation

// The cmux server privileged helper (plans/cmux-next/server.md 9.4). launchd
// starts it from the app's LaunchDaemon plist (scripts/cmux-next/bundle-server-helper.sh)
// with `--app <bundle id>`; it serves only that app, signed by its own team.

private func argument(_ name: String) -> String? {
    let arguments = CommandLine.arguments
    guard let index = arguments.firstIndex(of: name), arguments.indices.contains(index + 1) else { return nil }
    return arguments[index + 1]
}

guard let appBundleID = argument("--app"),
      let machServiceName = ServerHelperConstants().machServiceName(appBundleID: appBundleID) else {
    FileHandle.standardError.write(Data("cmux-server-helper: usage: cmux-server-helper --app <bundle id>\n".utf8))
    exit(64)
}

let service = ServerHelperService(priors: FileFixPriorStore.standard(label: machServiceName))
let listener = ServerHelperListener(machServiceName: machServiceName, appBundleID: appBundleID, service: service)
guard listener.acceptsClients else {
    FileHandle.standardError.write(Data("cmux-server-helper: unsigned or ad hoc helper; it serves nobody\n".utf8))
    exit(78)
}
listener.resume()
dispatchMain()
