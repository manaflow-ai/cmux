import Darwin
import Foundation

struct CLISocketTransportError: Error, CustomStringConvertible, CLISocketErrnoProviding {
    let message: String
    let socketErrnoValue: Int32

    init(message: String, errnoValue: Int32) {
        self.message = message
        self.socketErrnoValue = errnoValue
    }

    init(connectPath path: String, errnoValue: Int32) {
        let format = String(
            localized: "cli.socket.error.connectFailed",
            defaultValue: "Failed to connect to socket at %@ (%@, errno %lld)"
        )
        self.init(
            message: String.localizedStringWithFormat(
                format,
                path,
                String(cString: strerror(errnoValue)),
                Int64(errnoValue)
            ),
            errnoValue: errnoValue
        )
    }

    var description: String { message }
}
