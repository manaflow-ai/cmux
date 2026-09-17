/// The remote host's Go platform tuple (`GOOS`/`GOARCH`) as probed via
/// `uname`, lifted one-for-one from the legacy controller's nested type.
struct RemotePlatform {
    let goOS: String
    let goArch: String
}
