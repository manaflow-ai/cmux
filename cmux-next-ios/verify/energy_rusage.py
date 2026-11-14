#!/usr/bin/env python3
"""Read a process's wakeups, energy, CPU time and memory from the kernel (no root), for the energy bench.

    energy_rusage.py sample PID SECONDS OUT.jsonl   one proc_pid_rusage reading a second, SECONDS+1 lines
    energy_rusage.py once PID                       one reading, as JSON (a diagnostic)
    energy_rusage.py xctrace-rows XML PID           the rows of an `xctrace export` table that name PID

`proc_pid_rusage` (libproc, RUSAGE_INFO_V6, else V4) needs no root for a process of the caller's
own user, and the simulator's app is one. Its counters only grow, so a window's rates are the
difference of its last and first reading over the elapsed time:

- ri_interrupt_wkups: times the process was woken by an interrupt (timers, I/O). top's IDLEW is
  ri_pkg_idle_wkups, 0 for the simulator app on the fleet minis, so the bench reads interrupt wakeups.
- ri_energy_nj (V6): the kernel's energy estimate for the process, nanojoules; ri_billed_energy
  (V4, also nJ) when ri_energy_nj does not move.
- ri_user_time + ri_system_time: CPU time, mach absolute time units (scaled by mach_timebase_info).
- ri_phys_footprint: the memory footprint Xcode's gauge and Activity Monitor show, bytes.

cmux-next-ios/verify/energy.md has the bench.
"""
import ctypes
import json
import sys
import time
import xml.etree.ElementTree as ET

U64 = ctypes.c_uint64

V4_FIELDS = [
    "ri_user_time", "ri_system_time", "ri_pkg_idle_wkups", "ri_interrupt_wkups", "ri_pageins",
    "ri_wired_size", "ri_resident_size", "ri_phys_footprint", "ri_proc_start_abstime",
    "ri_proc_exit_abstime", "ri_child_user_time", "ri_child_system_time", "ri_child_pkg_idle_wkups",
    "ri_child_interrupt_wkups", "ri_child_pageins", "ri_child_elapsed_abstime", "ri_diskio_bytesread",
    "ri_diskio_byteswritten", "ri_cpu_time_qos_default", "ri_cpu_time_qos_maintenance",
    "ri_cpu_time_qos_background", "ri_cpu_time_qos_utility", "ri_cpu_time_qos_legacy",
    "ri_cpu_time_qos_user_initiated", "ri_cpu_time_qos_user_interactive", "ri_billed_system_time",
    "ri_serviced_system_time", "ri_logical_writes", "ri_lifetime_max_phys_footprint", "ri_instructions",
    "ri_cycles", "ri_billed_energy", "ri_serviced_energy", "ri_interval_max_phys_footprint",
    "ri_runnable_time",
]
V6_FIELDS = V4_FIELDS + [
    "ri_flags", "ri_user_ptime", "ri_system_ptime", "ri_pinstructions", "ri_pcycles", "ri_energy_nj",
    "ri_penergy_nj", "ri_secure_time_in_system", "ri_secure_ptime_in_system", "ri_neural_footprint",
    "ri_lifetime_max_neural_footprint", "ri_interval_max_neural_footprint",
]


def struct(fields, reserved):
    return type("rusage", (ctypes.Structure,), {
        "_fields_": [("ri_uuid", ctypes.c_uint8 * 16)] + [(f, U64) for f in fields] + [("ri_reserved", U64 * reserved)],
    })


FLAVORS = [(6, V6_FIELDS, struct(V6_FIELDS, 9)), (4, V4_FIELDS, struct(V4_FIELDS, 0))]
class Timebase(ctypes.Structure):
    _fields_ = [("numer", ctypes.c_uint32), ("denom", ctypes.c_uint32)]


_system = {}


def system():
    """libSystem (proc_pid_rusage, mach_timebase_info) and nanoseconds per mach tick, loaded on first use."""
    if not _system:
        lib = ctypes.CDLL("/usr/lib/libSystem.B.dylib", use_errno=True)
        lib.proc_pid_rusage.argtypes = [ctypes.c_int, ctypes.c_int, ctypes.c_void_p]
        lib.proc_pid_rusage.restype = ctypes.c_int
        tb = Timebase()
        lib.mach_timebase_info(ctypes.byref(tb))
        _system["lib"] = lib
        _system["ns_per_tick"] = tb.numer / tb.denom if tb.denom else 1.0
    return _system["lib"], _system["ns_per_tick"]


def read(pid):
    """One reading: every counter, plus the wall clock (s) and CPU time (ns), or None when the process is gone."""
    lib, ns_per_tick = system()
    for flavor, fields, cls in FLAVORS:
        buf = cls()
        if lib.proc_pid_rusage(pid, flavor, ctypes.byref(buf)) == 0:
            row = {f: getattr(buf, f) for f in fields}
            row["flavor"] = flavor
            row["t"] = time.monotonic()
            row["cpu_ns"] = (buf.ri_user_time + buf.ri_system_time) * ns_per_tick
            return row
    return None


def sample(pid, seconds, out):
    start = time.monotonic()
    with open(out, "w") as f:
        for i in range(seconds + 1):
            row = read(pid)
            if row is None:
                print(f"energy_rusage.py: pid {pid} gone after {i} readings", file=sys.stderr)
                return 1 if i < 2 else 0
            f.write(json.dumps(row) + "\n")
            f.flush()
            if i < seconds:
                time.sleep(max(0.0, start + i + 1 - time.monotonic()))
    return 0


def xctrace_rows(path, pid):
    """An `xctrace export --xpath` table: its column mnemonics, then each row naming PID (refs resolved)."""
    root = ET.parse(path).getroot()
    ids = {}
    for el in root.iter():
        if "id" in el.attrib:
            ids[el.attrib["id"]] = el.attrib.get("fmt") or (el.text or "").strip()
    for node in root.iter("node"):
        schema = node.find("schema")
        if schema is None:
            continue
        cols = [c.findtext("mnemonic") or "?" for c in schema.findall("col")]
        print(f"schema {schema.attrib.get('name')}: {' | '.join(cols)}")
        shown = 0
        for row in node.iter("row"):
            values = []
            for el in row:
                if "ref" in el.attrib:
                    values.append(ids.get(el.attrib["ref"], "?"))
                else:
                    values.append(el.attrib.get("fmt") or (el.text or "").strip())
            if any(f"({pid})" in v or v == str(pid) for v in values):
                print("  " + " | ".join(f"{c}={v}" for c, v in zip(cols, values)))
                shown += 1
        print(f"  ({shown} rows for pid {pid})")
    return 0


def main(argv):
    if argv[:1] == ["sample"] and len(argv) == 4:
        return sample(int(argv[1]), int(argv[2]), argv[3])
    if argv[:1] == ["once"] and len(argv) == 2:
        row = read(int(argv[1]))
        print(json.dumps(row) if row else "null")
        return 0 if row else 1
    if argv[:1] == ["xctrace-rows"] and len(argv) == 3:
        return xctrace_rows(argv[1], argv[2])
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
