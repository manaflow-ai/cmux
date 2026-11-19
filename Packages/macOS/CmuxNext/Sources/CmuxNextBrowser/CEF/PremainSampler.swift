import Foundation

/// Experiment (lane/rtc-premain-a, not for merge): at quit, starts a detached shell that waits for the next process
/// of this app's executable and `sample`s it for its first 2 s, printing the call graph to this process's stdout
/// (the relaunch bench keeps it in app.log / app-relaunched.log), with `ps` thread states while it starts.
nonisolated struct PremainSampler {
    static let script = #"""
    exe="$1"; old="$2"; out="/tmp/cmux-premain-sample-$old.txt"
    i=0
    while [ $i -lt 3000 ]; do
      new=$(pgrep -f -- "^$exe( |$)" | grep -v -x -e "$old" | head -n 1)
      if [ -n "$new" ]; then break; fi
      i=$((i+1)); sleep 0.005
    done
    [ -z "$new" ] && { echo "PREMAIN-SAMPLE none after $old"; exit 0; }
    t0=$(/usr/bin/perl -MTime::HiRes=time -e 'printf "%.3f", time')
    /usr/bin/sample "$new" 2 1 -mayDie -file "$out" >/dev/null 2>&1 &
    for k in 1 2 3 4 5 6; do
      sleep 0.2
      echo "PREMAIN-PS $new t+$((k*200))ms $(ps -o stat=,time= -p "$new" 2>/dev/null)"
    done
    wait
    echo "PREMAIN-SAMPLE BEGIN new=$new old=$old found_at=$t0"
    sed -n '1,400p' "$out" 2>/dev/null | sed 's/^/PREMAIN-SAMPLE /'
    echo "PREMAIN-SAMPLE END"
    """#

    static func start() {
        guard let executable = Bundle.main.executableURL?.path else { return }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "premain-sampler", executable, String(getpid())]
        try? process.run()
    }
}
