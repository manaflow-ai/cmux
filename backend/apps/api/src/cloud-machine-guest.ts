import { shellQuote } from "@cmux/cloud-env"
import type { MachineExecReply } from "./automation-machine.ts"
import { readBody } from "./cloud-acpmux.ts"
import { callerFor } from "./cloud-client-session.ts"
import { asWorkUser } from "./cloud-env-sandbox.ts"
import { PLATFORM_EXEC_MAX_MS } from "./cloud-platform.ts"
import type { Env } from "./env.ts"

/**
 * Exec and files on a Cloud (CloudDO) machine, in the shapes of classic cmux.com /api/vm/{id}/exec and
 * /api/vm/{id}/fs/{op} (web/app/api/vm/[id]/...), so `cmux cloud deliver-secrets`, apply-machine-config
 * and credential recovery work on app-server machines with the client's classic request and answer
 * code (cmux-platform#89, piece B):
 *
 *   POST   /v1/cloud/machines/{machine}/exec              {command, timeoutMs?} -> {exitCode, stdout, stderr}
 *          (30 s default; at most 5 min, the provider's inline exec limit, where classic allows 15; at
 *          most OUTPUT_MAX_BYTES of each stream, then a truncation note on stderr)
 *   GET    /v1/cloud/machines/{machine}/fs/dir?path=      -> {entries: [{name, kind, size, mode, modifiedAt}]}
 *   GET    /v1/cloud/machines/{machine}/fs/read?path=     -> {path, dataBase64, size}
 *   GET    /v1/cloud/machines/{machine}/fs/stat?path=     -> {path, kind, size, mode, modifiedAt}
 *   POST   /v1/cloud/machines/{machine}/fs/write          {path, dataBase64, mode?} -> {ok: true, path}
 *   POST   /v1/cloud/machines/{machine}/fs/mkdir          {path} -> {ok: true, path}
 *   DELETE /v1/cloud/machines/{machine}/fs/remove?path=   -> {ok: true, path}
 *
 * Plain HTTP routes outside the op path (like client-session): a command, a file's content and a
 * secret on its way to the machine never become an op, an event, a ledger row or a log line; the
 * audit row holds who, the machine and the exit code. Who: a person's session, or a cli or mac
 * install with execute (never an agent or a machine's own install), for a machine of the selected
 * team while they may use its machines (CloudDO.ownerExec), as classic lets any member of the owning
 * team. Exec runs as the image's work user; the file operations run as root, as classic's file API
 * does (a new file is root's; an existing one keeps its owner). A refusal answers
 * {ok: false, error: {code, message}} with the classic code, also in the x-cmux-vm-error header.
 */
export const GUEST_PATH = /^\/v1\/cloud\/machines\/(vm_[a-z0-9]{20})\/(exec|fs\/(?:dir|read|stat|write|mkdir|remove))$/

type Op = "exec" | "fs/dir" | "fs/read" | "fs/stat" | "fs/write" | "fs/mkdir" | "fs/remove"
const METHOD: Readonly<Record<Op, string>> = { exec: "POST", "fs/dir": "GET", "fs/read": "GET", "fs/stat": "GET", "fs/write": "POST", "fs/mkdir": "POST", "fs/remove": "DELETE" }

/** Classic's limits: a 64 KiB command, a 30 s default exec, a 4096 byte absolute path. */
export const COMMAND_MAX_BYTES = 64 * 1024
export const EXEC_DEFAULT_MS = 30_000
/** The provider answers an exec inline for at most 5 minutes (classic's 15 needs its own background exec). */
export const EXEC_MAX_MS = PLATFORM_EXEC_MAX_MS
/** Each of an exec's stdout and stderr, kept on the machine: the rest is read and dropped there. */
export const OUTPUT_MAX_BYTES = 1024 * 1024
const PATH_MAX_BYTES = 4096
/** One file read or write (classic allows 16 MiB; this one crosses the provider's exec as stdin or stdout). */
export const FILE_MAX_BYTES = 8 * 1024 * 1024
/** A directory listing's entries (classic's limit). */
export const DIR_MAX_ENTRIES = 10_000
/**
 * A directory listing's JSON, as the file program writes it. json.dumps escapes every control and
 * non-ASCII character, so that JSON is printable ASCII; the provider's JSON around it escapes each such
 * byte as at most 6 (\u003c at worst), so a listing of at most DIR_MAX_BYTES stays within 12 MiB of the
 * provider's answer, under EXEC_RESPONSE_MAX_BYTES (providers/freestyle/exec.ts). Without it, 10,000
 * names of 255 control characters would be about 18.6 MiB there. freestyle-exec-errors.test.ts checks it.
 */
export const DIR_MAX_BYTES = 2 * 1024 * 1024
const FS_TIMEOUT_MS = 60_000
/** A write's JSON body: the base64 of the largest file plus its path and mode. */
const BODY_MAX = Math.ceil(FILE_MAX_BYTES / 3) * 4 + 16 * 1024

const NO_STORE = { "cache-control": "no-store" }
const refuse = (status: number, code: string, message: string) => Response.json({ ok: false, error: { code, message } }, { status, headers: { ...NO_STORE, "x-cmux-vm-error": code } })
const ok = (value: unknown) => Response.json(value, { headers: NO_STORE })

/** The file program's exit codes for what classic answers as its own errors. */
const NOT_FOUND = 44
const WRONG_KIND = 45
const TOO_LARGE = 46
/** A remove whose path resolves to the machine's root (see the remove branch below). */
const ROOT = 47

/**
 * The file operations, run with python3 as root on the machine (the image has it: the machine-config
 * applier and the credential installer use it). argv: op, path, and for a write its mode. A write
 * replaces the file atomically (a temporary file in the same folder, then rename); a new file without
 * a mode is 0600, as classic's.
 *
 * A remove first drops trailing "." and "/" segments (so a symlink named with them is removed itself, never its
 * target's contents) and refuses a path that resolves to "/" (`/proc/self/root/.`, a symlink to the root).
 */
export const FS_PROGRAM = `import base64,json,os,shutil,stat,sys,tempfile
op,p=sys.argv[1],sys.argv[2]
M=${FILE_MAX_BYTES}
DN,DB=${DIR_MAX_ENTRIES},${DIR_MAX_BYTES}
def k(m):return "directory" if stat.S_ISDIR(m) else "symlink" if stat.S_ISLNK(m) else "file"
def i(s):return {"kind":k(s.st_mode),"size":s.st_size,"mode":stat.S_IMODE(s.st_mode),"modifiedAt":int(s.st_mtime*1000)}
try:
 if op=="stat":o={"path":p,**i(os.lstat(p))}
 elif op=="dir":
  e=[];n=16
  with os.scandir(p) as d:
   for x in d:
    if len(e)>=DN:sys.exit(${TOO_LARGE})
    y={"name":x.name,**i(x.stat(follow_symlinks=False))}
    n+=len(json.dumps(y))+2
    if n>DB:sys.exit(${TOO_LARGE})
    e.append(y)
  o={"entries":e}
 elif op=="read":
  s=os.stat(p)
  if stat.S_ISDIR(s.st_mode):sys.exit(${WRONG_KIND})
  if s.st_size>M:sys.exit(${TOO_LARGE})
  with open(p,"rb") as f:b=f.read(M+1)
  if len(b)>M:sys.exit(${TOO_LARGE})
  o={"path":p,"dataBase64":base64.b64encode(b).decode(),"size":len(b)}
 elif op=="write":
  b=sys.stdin.buffer.read()
  old=None
  try:old=os.stat(p)
  except FileNotFoundError:pass
  if old and stat.S_ISDIR(old.st_mode):sys.exit(${WRONG_KIND})
  m=int(sys.argv[3]) if len(sys.argv)>3 else (stat.S_IMODE(old.st_mode) if old else 0o600)
  fd,t=tempfile.mkstemp(dir=os.path.dirname(p),prefix=".cmux-write-")
  try:
   with os.fdopen(fd,"wb") as f:
    f.write(b);f.flush();os.fchmod(f.fileno(),m)
    if old:os.fchown(f.fileno(),old.st_uid,old.st_gid)
    os.fsync(f.fileno())
   os.replace(t,p)
  except BaseException:
   try:os.unlink(t)
   except OSError:pass
   raise
  o={"ok":True,"path":p}
 elif op=="mkdir":
  os.makedirs(p,exist_ok=True)
  o={"ok":True,"path":p}
 elif op=="remove":
  q=os.path.normpath(p)
  if os.path.realpath(q)=="/":sys.exit(${ROOT})
  s=os.lstat(q)
  if stat.S_ISDIR(s.st_mode):shutil.rmtree(q)
  else:os.unlink(q)
  o={"ok":True,"path":p}
 else:sys.exit(2)
except FileNotFoundError:sys.exit(${NOT_FOUND})
except (NotADirectoryError,IsADirectoryError,FileExistsError):sys.exit(${WRONG_KIND})
sys.stdout.write(json.dumps(o))
`

/**
 * Runs `bash -c argv[2]` with no stdin and passes through at most argv[1] bytes of each of its stdout
 * and stderr as they come (so output before a timeout is not lost), reading and dropping the rest; a
 * command that writes without end costs the machine's CPU until its timeout, never memory, disk or
 * the answer's size. It ends half a second after the command exits, even when a child the command
 * left running (`setsid x &`, `sleep 600 &`) still holds the pipes. Answers the command's own exit
 * code (128 + n for signal n).
 */
export const OUTPUT_CAP_PROGRAM = `import os,selectors,subprocess,sys,time
n=int(sys.argv[1])
p=subprocess.Popen(["bash","-c",sys.argv[2]],stdin=subprocess.DEVNULL,stdout=subprocess.PIPE,stderr=subprocess.PIPE)
def wr(f,b):
 while b:b=b[os.write(f,b):]
o={p.stdout.fileno():[1,0],p.stderr.fileno():[2,0]}
cut=False
s=selectors.DefaultSelector()
for f in o:
 os.set_blocking(f,False);s.register(f,selectors.EVENT_READ)
end=None
while s.get_map():
 if end is None and p.poll() is not None:end=time.monotonic()+0.5
 if end is not None and time.monotonic()>=end:break
 for k,_ in s.select(0.1):
  try:d=os.read(k.fd,65536)
  except BlockingIOError:continue
  if not d:
   s.unregister(k.fd);continue
  w=o[k.fd]
  if w[1]+len(d)>n:cut=True
  keep=d[:max(0,n-w[1])]
  if keep:
   wr(w[0],keep);w[1]+=len(keep)
r=p.wait()
if cut:wr(2,b"\\ncmux: output cut at %d bytes per stream\\n"%n)
sys.exit(r if r>=0 else 128-r)
`

/** An exec's command as the work user, with its output capped on the machine. */
export const execCommand = (command: string): string => asWorkUser(["python3", "-c", shellQuote(OUTPUT_CAP_PROGRAM), String(OUTPUT_MAX_BYTES), shellQuote(command)].join(" "))

/** The root command for one file operation. */
export const fsCommand = (op: "dir" | "read" | "stat" | "write" | "mkdir" | "remove", path: string, mode?: number): string =>
  ["python3", "-c", shellQuote(FS_PROGRAM), op, shellQuote(path), ...(mode === undefined ? [] : [String(mode)])].join(" ")

/** Classic's path rule, after its trim: absolute, no NUL, no `..` segment, at most 4096 bytes. */
export const validPath = (path: unknown): path is string =>
  typeof path === "string" && path.startsWith("/") && !path.includes("\0") && !path.split("/").includes("..") && new TextEncoder().encode(path).byteLength <= PATH_MAX_BYTES

/** Strict standard base64 (classic's rule), decoded; null when it is not. */
export const decodeBase64 = (s: unknown): Uint8Array | null => {
  if (typeof s !== "string" || s.length % 4 !== 0 || !/^[A-Za-z0-9+/]*={0,2}$/.test(s)) return null
  try {
    return Uint8Array.from(atob(s), (c) => c.charCodeAt(0))
  } catch {
    return null
  }
}

/** The timeout an exec asks for: absent, not a number or not positive is classic's 30 s; longer than EXEC_MAX_MS is EXEC_MAX_MS. */
export const execTimeout = (v: unknown): number => (typeof v === "number" && Number.isFinite(v) && v > 0 ? Math.min(Math.floor(v), EXEC_MAX_MS) || 1 : EXEC_DEFAULT_MS)

type Stub = { ownerExec(entity: string, user: string, machine: string, command: string, stdin: Uint8Array | null, timeoutMs: number): Promise<MachineExecReply> }

const REFUSAL: Readonly<Record<Exclude<MachineExecReply, { ok: true }>["refusal"], [number, string, string]>> = {
  not_found: [404, "vm_not_found", "no such machine in this team"],
  forbidden: [403, "vm_forbidden", "this user may not use the team's machines"],
  not_running: [409, "vm_not_running", "the machine is not running; start it first"],
  provider_failed: [502, "vm_unavailable", "the machine did not answer; retry"],
  output_limit: [413, "vm_output_too_large", "the machine's answer exceeded the response limit; its output was discarded"]
}

/** A JSON object body of at most BODY_MAX bytes, or the refusal. */
const jsonBody = async (request: Request): Promise<Record<string, unknown> | Response> => {
  const declared = Number(request.headers.get("content-length") ?? "0")
  if (!(declared >= 0 && declared <= BODY_MAX)) return refuse(413, "vm_file_too_large", "the request body is too large")
  const bytes = await readBody(request, BODY_MAX).catch(() => null)
  if (bytes === null) return refuse(413, "vm_file_too_large", "the request body is too large")
  let body: unknown
  try {
    body = JSON.parse(new TextDecoder().decode(bytes))
  } catch {
    return refuse(400, "vm_invalid_json", "the request body is not JSON")
  }
  return body !== null && typeof body === "object" && !Array.isArray(body) ? (body as Record<string, unknown>) : refuse(400, "vm_invalid_request", "the request body must be a JSON object")
}

export const handleCloudMachineGuest = async (request: Request, env: Env, machine: string, op: Op): Promise<Response> => {
  if (request.method !== METHOD[op]) return Response.json({ ok: false, error: { code: "vm_method_not_allowed", message: `${METHOD[op]} only` } }, { status: 405, headers: { allow: METHOD[op], ...NO_STORE } })
  const url = new URL(request.url)
  const principal = await callerFor(request, env, [403, "auth.forbidden", "machine exec and files need a person's session or a cmux CLI or Mac install"])
  if (principal instanceof Response) return principal
  const stub = env.CLOUD_DO.get(env.CLOUD_DO.idFromName(principal.team!)) as unknown as Stub
  const run = async (command: string, stdin: Uint8Array | null, timeoutMs: number): Promise<{ exitCode: number; stdout: string; stderr: string } | Response> => {
    let r: MachineExecReply
    try {
      r = await stub.ownerExec(principal.team!, principal.user!, machine, command, stdin, timeoutMs)
    } catch {
      return refuse(503, "vm_unavailable", "the Cloud service could not be reached; retry")
    }
    return r.ok ? r : refuse(...REFUSAL[r.refusal])
  }

  if (op === "exec") {
    const body = await jsonBody(request)
    if (body instanceof Response) return body
    const command = body.command
    if (typeof command !== "string" || command.trim() === "") return refuse(400, "vm_invalid_command", "command must be a non-empty string")
    if (new TextEncoder().encode(command).byteLength > COMMAND_MAX_BYTES) return refuse(413, "vm_command_too_large", `the command is over ${COMMAND_MAX_BYTES} bytes`)
    const r = await run(execCommand(command), null, execTimeout(body.timeoutMs))
    return r instanceof Response ? r : ok({ exitCode: r.exitCode, stdout: r.stdout, stderr: r.stderr })
  }

  const fsOp = op.slice(3) as "dir" | "read" | "stat" | "write" | "mkdir" | "remove"
  let path: unknown
  let mode: number | undefined
  let stdin: Uint8Array | null = null
  if (request.method === "POST") {
    const body = await jsonBody(request)
    if (body instanceof Response) return body
    path = typeof body.path === "string" ? body.path.trim() : body.path
    if (fsOp === "write") {
      if (body.mode !== undefined && !(typeof body.mode === "number" && Number.isInteger(body.mode) && body.mode >= 0 && body.mode <= 0o7777)) return refuse(400, "vm_invalid_file_mode", "mode must be an integer from 0 to 4095")
      mode = body.mode as number | undefined
      stdin = decodeBase64(body.dataBase64)
      if (stdin === null) return refuse(400, "vm_invalid_file_body", "dataBase64 must be standard base64")
      if (stdin.byteLength > FILE_MAX_BYTES) return refuse(413, "vm_file_too_large", `the file is over ${FILE_MAX_BYTES} bytes`)
    }
  } else path = url.searchParams.get("path")?.trim()
  // Removing the root is refused however it is spelled: "/", "///", "/." or "/./".
  if (!validPath(path) || (fsOp === "remove" && path.split("/").every((segment) => segment === "" || segment === "."))) return refuse(400, "vm_invalid_path", "path must be absolute, without a .. segment, at most 4096 bytes")
  const r = await run(fsCommand(fsOp, path, mode), stdin, FS_TIMEOUT_MS)
  stdin?.fill(0)
  if (r instanceof Response) return r
  if (r.exitCode === NOT_FOUND) return refuse(404, "vm_file_not_found", `no such file: ${path}`)
  if (fsOp === "remove" && r.exitCode === ROOT) return refuse(400, "vm_invalid_path", "the path is the machine's root")
  if (r.exitCode === WRONG_KIND) return refuse(400, "vm_invalid_path", fsOp === "dir" ? "not a directory" : "the path is a directory, or a part of it is a file")
  if (r.exitCode === TOO_LARGE) return refuse(413, "vm_file_too_large", fsOp === "dir" ? `the directory has over ${DIR_MAX_ENTRIES} entries, or its listing is over ${DIR_MAX_BYTES} bytes` : `the file is over ${FILE_MAX_BYTES} bytes`)
  let value: unknown = null
  try {
    value = r.exitCode === 0 ? JSON.parse(r.stdout) : null
  } catch {}
  if (value === null || typeof value !== "object") return refuse(502, "vm_file_operation_failed", (r.stderr || r.stdout).slice(-500) || `the file operation exited ${r.exitCode}`)
  return ok(value)
}
