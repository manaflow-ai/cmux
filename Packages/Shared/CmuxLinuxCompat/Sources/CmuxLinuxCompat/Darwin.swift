#if canImport(Glibc)
import Glibc

/// The libc calls first-party code spells with a `Darwin.` qualifier, for
/// Linux builds. Each member forwards to the Glibc function of the same name
/// with the same arguments. A file reaches this type by importing
/// `CmuxLinuxCompat` under `#if canImport(CmuxLinuxCompat)`; Apple builds
/// keep the real module.
// lint:allow namespace-type: mirrors the Darwin module's qualified calls (`Darwin.close(fd)`) so call sites compile unchanged.
public enum Darwin {
    public static var errno: Int32 {
        get { Glibc.errno }
        set { Glibc.errno = newValue }
    }

    // Files and descriptors.
    @inlinable public static func open(_ path: UnsafePointer<CChar>, _ flags: Int32) -> Int32 { Glibc.open(path, flags) }
    @inlinable public static func open(_ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32 { Glibc.open(path, flags, mode) }
    @inlinable public static func openat(_ fd: Int32, _ path: UnsafePointer<CChar>, _ flags: Int32) -> Int32 { Glibc.openat(fd, path, flags) }
    @inlinable public static func openat(_ fd: Int32, _ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32 { Glibc.openat(fd, path, flags, mode) }
    @inlinable public static func close(_ fd: Int32) -> Int32 { Glibc.close(fd) }
    @inlinable public static func read(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int) -> Int { Glibc.read(fd, buffer, count) }
    @inlinable public static func pread(_ fd: Int32, _ buffer: UnsafeMutableRawPointer?, _ count: Int, _ offset: off_t) -> Int { Glibc.pread(fd, buffer, count, offset) }
    @inlinable public static func write(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int) -> Int { Glibc.write(fd, buffer, count) }
    @inlinable public static func lseek(_ fd: Int32, _ offset: off_t, _ whence: Int32) -> off_t { Glibc.lseek(fd, offset, whence) }
    @inlinable public static func fsync(_ fd: Int32) -> Int32 { Glibc.fsync(fd) }
    @inlinable public static func ftruncate(_ fd: Int32, _ length: off_t) -> Int32 { Glibc.ftruncate(fd, length) }
    @inlinable public static func flock(_ fd: Int32, _ operation: Int32) -> Int32 { libcFlock(fd, operation) }
    @inlinable public static func fcntl(_ fd: Int32, _ command: Int32) -> Int32 { Glibc.fcntl(fd, command) }
    @inlinable public static func fcntl(_ fd: Int32, _ command: Int32, _ value: Int32) -> Int32 { Glibc.fcntl(fd, command, value) }
    @inlinable public static func fcntl(_ fd: Int32, _ command: Int32, _ pointer: UnsafeMutableRawPointer) -> Int32 { Glibc.fcntl(fd, command, pointer) }
    @inlinable public static func dup(_ fd: Int32) -> Int32 { Glibc.dup(fd) }
    @inlinable public static func pipe(_ fds: UnsafeMutablePointer<Int32>) -> Int32 { Glibc.pipe(fds) }
    @inlinable public static func poll(_ fds: UnsafeMutablePointer<pollfd>?, _ count: nfds_t, _ timeout: Int32) -> Int32 { Glibc.poll(fds, count, timeout) }
    @inlinable public static func fstat(_ fd: Int32, _ buffer: UnsafeMutablePointer<Glibc.stat>) -> Int32 { Glibc.fstat(fd, buffer) }
    @inlinable public static func stat(_ path: UnsafePointer<CChar>, _ buffer: UnsafeMutablePointer<Glibc.stat>) -> Int32 { libcStat(path, buffer) }
    @inlinable public static func lstat(_ path: UnsafePointer<CChar>, _ buffer: UnsafeMutablePointer<Glibc.stat>) -> Int32 { Glibc.lstat(path, buffer) }

    // Paths.
    @inlinable public static func access(_ path: UnsafePointer<CChar>, _ mode: Int32) -> Int32 { Glibc.access(path, mode) }
    @inlinable public static func chmod(_ path: UnsafePointer<CChar>, _ mode: mode_t) -> Int32 { Glibc.chmod(path, mode) }
    @inlinable public static func fchmod(_ fd: Int32, _ mode: mode_t) -> Int32 { Glibc.fchmod(fd, mode) }
    @inlinable public static func mkdir(_ path: UnsafePointer<CChar>, _ mode: mode_t) -> Int32 { Glibc.mkdir(path, mode) }
    @inlinable public static func mkfifo(_ path: UnsafePointer<CChar>, _ mode: mode_t) -> Int32 { Glibc.mkfifo(path, mode) }
    @inlinable public static func link(_ from: UnsafePointer<CChar>, _ to: UnsafePointer<CChar>) -> Int32 { Glibc.link(from, to) }
    @inlinable public static func unlink(_ path: UnsafePointer<CChar>) -> Int32 { Glibc.unlink(path) }
    @inlinable public static func rename(_ from: UnsafePointer<CChar>, _ to: UnsafePointer<CChar>) -> Int32 { Glibc.rename(from, to) }
    @inlinable public static func realpath(_ path: UnsafePointer<CChar>, _ resolved: UnsafeMutablePointer<CChar>?) -> UnsafeMutablePointer<CChar>? { Glibc.realpath(path, resolved) }
    @inlinable public static func shm_unlink(_ name: UnsafePointer<CChar>) -> Int32 { Glibc.shm_unlink(name) }

    // Processes and signals.
    @inlinable public static func kill(_ pid: pid_t, _ signal: Int32) -> Int32 { Glibc.kill(pid, signal) }
    @inlinable public static func killpg(_ group: pid_t, _ signal: Int32) -> Int32 { Glibc.killpg(group, signal) }
    @inlinable public static func raise(_ signal: Int32) -> Int32 { Glibc.raise(signal) }
    @inlinable public static func signal(_ signal: Int32, _ handler: sighandler_t?) -> sighandler_t? { Glibc.signal(signal, handler) }
    @inlinable public static func waitpid(_ pid: pid_t, _ status: UnsafeMutablePointer<Int32>?, _ options: Int32) -> pid_t { Glibc.waitpid(pid, status, options) }
    @inlinable public static func getuid() -> uid_t { Glibc.getuid() }
    @inlinable public static func geteuid() -> uid_t { Glibc.geteuid() }

    // Sockets.
    @inlinable public static func socket(_ domain: Int32, _ type: Int32, _ proto: Int32) -> Int32 { Glibc.socket(domain, type, proto) }
    @inlinable public static func socketpair(_ domain: Int32, _ type: Int32, _ proto: Int32, _ fds: UnsafeMutablePointer<Int32>) -> Int32 { Glibc.socketpair(domain, type, proto, fds) }
    @inlinable public static func bind(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 { Glibc.bind(fd, address, length) }
    @inlinable public static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>, _ length: socklen_t) -> Int32 { Glibc.connect(fd, address, length) }
    @inlinable public static func listen(_ fd: Int32, _ backlog: Int32) -> Int32 { Glibc.listen(fd, backlog) }
    @inlinable public static func accept(_ fd: Int32, _ address: UnsafeMutablePointer<sockaddr>?, _ length: UnsafeMutablePointer<socklen_t>?) -> Int32 { Glibc.accept(fd, address, length) }
    @inlinable public static func getsockname(_ fd: Int32, _ address: UnsafeMutablePointer<sockaddr>, _ length: UnsafeMutablePointer<socklen_t>) -> Int32 { Glibc.getsockname(fd, address, length) }
    @inlinable public static func send(_ fd: Int32, _ buffer: UnsafeRawPointer?, _ count: Int, _ flags: Int32) -> Int { Glibc.send(fd, buffer, count, flags) }
    @inlinable public static func shutdown(_ fd: Int32, _ how: Int32) -> Int32 { Glibc.shutdown(fd, how) }
}

// `Glibc.flock` and `Glibc.stat` name the structs, so the calls are made
// unqualified at file scope, where overload resolution finds the functions.
@usableFromInline func libcFlock(_ fd: Int32, _ operation: Int32) -> Int32 { flock(fd, operation) }
@usableFromInline func libcStat(_ path: UnsafePointer<CChar>, _ buffer: UnsafeMutablePointer<Glibc.stat>) -> Int32 { stat(path, buffer) }
#endif
