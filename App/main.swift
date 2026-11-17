// Xcode target `cmux-next`: all app code lives in Packages/macOS/CmuxNext.
//
// Contents/MacOS/cmux is this stub; the code is Contents/Frameworks/CmuxNextApp.framework
// (Packages/macOS/CmuxNext/Package.swift, CMUX-629). Chromium's code-sign clone hard-links
// the main executable on every launch, and XProtect then scans that file again before the
// next launch: a stub costs milliseconds, the 100 MB executable cost about 500 ms.
// The framework exports only `cmux_next_app_main` (CmuxNextApp.swift); a live code
// build links CmuxNextApp statically and still exports it.
//
// THROWAWAY experiment A (lane/fresh-install-expA, not for merge): the stub links no
// CmuxNextApp at load time (no symbol reference, -dead_strip_dylibs), so dyld runs its
// main before loading the framework. It marks `stub_main` first, then dlopens the framework.
import Darwin

// The launch mark `stub_main <ms since process start>`, in LaunchMarkSink's format, to the
// FIFO CMUX_NEXT_LAUNCH_MARKS_PATH (only when no CMUX_NEXT_LAUNCH_MARKS_FD, as the app does).
// The descriptor stays open so the reader never sees EOF before the app opens its own.
do {
    var now = timeval()
    gettimeofday(&now, nil)
    if getenv("CMUX_NEXT_LAUNCH_MARKS_FD") == nil, let path = getenv("CMUX_NEXT_LAUNCH_MARKS_PATH") {
        let fd = open(path, O_WRONLY | O_NONBLOCK | O_CLOEXEC)
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()]
        if fd >= 0, sysctl(&mib, 4, &info, &size, nil, 0) == 0 {
            let start = info.kp_proc.p_un.__p_starttime
            let tenths = ((Int(now.tv_sec) - Int(start.tv_sec)) * 1_000_000 + Int(now.tv_usec) - Int(start.tv_usec)) / 100
            let line = "stub_main \(tenths / 10).\(tenths % 10)\n"
            _ = line.withCString { write(fd, $0, strlen($0)) }
        }
    }
}

#if CMUX_LIVE_CODE
// A live code build links CmuxNextApp statically: keep the reference so the link keeps it.
@_silgen_name("cmux_next_app_main")
func cmuxNextAppMain()
cmuxNextAppMain()
#else
typealias AppMain = @convention(c) () -> Void
var entry = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "cmux_next_app_main") // RTLD_DEFAULT
if entry == nil {
    // dyld expands @executable_path in dlopen to this executable's directory (Contents/MacOS).
    let framework = "@executable_path/../Frameworks/CmuxNextApp.framework/CmuxNextApp"
    guard let handle = dlopen(framework, RTLD_NOW) else {
        fputs("cmux: dlopen \(framework): \(dlerror().map { String(cString: $0) } ?? "unknown")\n", stderr); exit(1)
    }
    entry = dlsym(handle, "cmux_next_app_main")
}
guard let entry else {
    fputs("cmux: dlsym cmux_next_app_main: \(dlerror().map { String(cString: $0) } ?? "unknown")\n", stderr); exit(1)
}
unsafeBitCast(entry, to: AppMain.self)()
#endif
