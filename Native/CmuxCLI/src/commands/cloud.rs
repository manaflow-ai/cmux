//! Cloud VM, VPN, domains, sidebar, reflection, and remotes commands.
//!
//! This module deliberately contains only presentation and argument handling. The
//! app remains the authority for Cloud state; every operation maps to the legacy
//! v2 socket method documented beside its Swift implementation.

use crate::{CliError, Context, Result};
use serde_json::{Map, Value, json};
use std::net::IpAddr;

const VM_USAGE: &str = "Usage: cmux vm <base|new|ls|status|stats|resize|rename|pause|resume|snapshot|fork|restore|rm|promote-template|domains|self|tree|run|route|agent|dev|exec|push|pull|wait|shell|tui|desktop|open|workspace|terminal|layout|env|tab|attach|ssh> [args...]";
const DOMAIN_USAGE: &str =
    "Usage: cmux cloud domains [list|zones|verify|publish|access|grant|ungrant|grants|rm] ...";
const REMOTES_USAGE: &str = "Usage: cmux remotes <list|add|remove> [options]";

/// Dispatch commands owned by this module. Commands delegated to the transfer
/// worker return `Ok(None)` so the root dispatcher can continue routing them.
pub fn run(ctx: &Context, command: &str, args: &[String]) -> Result<Option<i32>> {
    match command {
        "vm" | "cloud" => run_vm(ctx, args),
        "vpn" => run_vpn(ctx, args),
        "remotes" | "remote" => run_remotes(ctx, args),
        _ => Ok(None),
    }
}

fn run_vm(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let sub = args
        .first()
        .map(|s| s.to_ascii_lowercase())
        .unwrap_or_else(|| "ls".into());
    let rest = &args[1..];
    match sub.as_str() {
        "help" | "--help" | "-h" => {
            ctx.print(VM_USAGE)?;
            Ok(Some(0))
        }
        "domains" => run_domains(ctx, rest),
        "base" => run_base(ctx, rest),
        "ls" | "list" => run_vm_list(ctx, rest),
        "new" | "create" => run_vm_new(ctx, rest),
        "status" | "info" => run_vm_status(ctx, rest),
        "stats" | "top" => run_vm_stats(ctx, rest),
        "resize" => run_vm_resize(ctx, rest),
        "rename" => run_vm_rename(ctx, rest),
        "pause" | "resume" => run_vm_lifecycle(ctx, &sub, rest),
        "snapshot" | "checkpoint" => run_snapshot(ctx, rest),
        "fork" => run_vm_fork(ctx, rest),
        "restore" => run_vm_restore(ctx, rest),
        "rm" | "destroy" | "delete" => run_vm_rm(ctx, rest),
        "promote-template" => run_promote_template(ctx, rest),
        "tree" if rest.iter().any(|x| x == "--sidebar") => run_sidebar(ctx, rest),
        "self" => run_vm_self(ctx, rest),
        // Implemented by cloud execution/terminal workers.
        "run" | "route" | "agent" | "dev" | "exec" | "push" | "upload" | "pull" | "download"
        | "wait" | "shell" | "attach" | "tui" | "desktop" | "vnc" | "open" | "workspace"
        | "terminal" | "layout" | "env" | "tab" | "ssh" | "ssh-info" | "ssh-attach" | "prompt"
        | "skill" | "ports" | "tools" | "tool-inspector" | "handoff" => Ok(None),
        _ => Err(CliError::usage(VM_USAGE)),
    }
}

fn run_vm_new(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    if args.iter().any(|x| x == "--help" || x == "-h") {
        ctx.print("Usage: cmux vm new [--image <id>] [--provider <provider>] [--size <4g|8g|16g|24g|32g|64g>] [--name <label>] [--detach|-d]")?;
        return Ok(Some(0));
    }
    let mut image = None;
    let mut provider = None;
    let mut size = None;
    let mut name = None;
    let mut detach = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--image" => image = Some(next(args, &mut i)?),
            "--provider" => provider = Some(next(args, &mut i)?),
            "--size" => size = Some(next(args, &mut i)?),
            "--name" => name = Some(next(args, &mut i)?),
            "--detach" | "-d" => detach = true,
            x if x == "--desktop" || x == "--base" || x == "--no-desktop" => {}
            x if !x.starts_with('-') => {
                return Err(CliError::usage("cmux vm new takes no positional arguments"));
            }
            _ => {
                return Err(CliError::usage(
                    "Usage: cmux vm new [--image <id>] [--provider <provider>] [--size <4g|8g|16g|24g|32g|64g>] [--name <label>] [--detach|-d]",
                ));
            }
        }
        i += 1;
    }
    let mut p = json!({"idempotency_key": uuid::Uuid::new_v4().to_string()});
    if let Some(v) = image {
        p["image"] = json!(v);
    } else {
        p["kind"] = json!("desktop");
    }
    if let Some(v) = provider {
        p["provider"] = json!(v);
    }
    if let Some(v) = size {
        p["memory_mb"] = json!(parse_size_mb(&v)?);
    }
    let r = ctx.rpc("vm.create", p)?;
    let id = strv(&r, "id", "?");
    if ctx.json {
        ctx.emit(&r)?;
    } else if detach {
        ctx.print(format!("{} is ready\n\n  shell    cmux vm shell {}\n  run      cmux vm exec {} -- uname -a\n  remove   cmux vm rm {}", id, id, id, id))?;
    } else {
        ctx.print(format!("Created Cloud VM {}\nOK machine={}", id, id))?;
    }
    if let Some(label) = name.filter(|x| !x.is_empty()) {
        let _ = ctx.rpc("vm.rename", json!({"id":id,"display_name":label}));
    }
    Ok(Some(0))
}
fn parse_size_mb(raw: &str) -> Result<i64> {
    let x = raw.to_ascii_lowercase();
    let n = x
        .trim_end_matches("gib")
        .trim_end_matches("gb")
        .trim_end_matches('g');
    let gib: i64 = n
        .parse()
        .map_err(|_| CliError::usage("size must be a memory preset or MB"))?;
    if [4, 8, 16, 24, 32, 64].contains(&gib) {
        Ok(gib * 1024)
    } else if gib >= 512 && !x.contains('g') {
        Ok(gib)
    } else {
        Err(CliError::usage(
            "size must be 4g, 8g, 16g, 24g, 32g, 64g, or memory in MB",
        ))
    }
}

fn run_vm_list(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    if !args.is_empty() && !(args.len() == 1 && args[0] == "--json") {
        return Err(CliError::usage("Usage: cmux vm ls [--json]"));
    }
    let response = ctx.rpc("vm.list", json!({}))?;
    if ctx.json {
        ctx.emit(&response)?;
        return Ok(Some(0));
    }
    let vms = response
        .get("vms")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if vms.is_empty() {
        ctx.print("No cloud VMs. Try: cmux vm new")?;
        return Ok(Some(0));
    }
    let mut rows = Vec::new();
    for vm in &vms {
        let id = strv(vm, "id", "?");
        let label = nonempty(strv(vm, "displayName", ""))
            .or_else(|| nonempty(strv(vm, "slug", "")))
            .unwrap_or_else(|| id.clone());
        rows.push((
            id,
            label,
            strv(vm, "status", "unknown"),
            strv(vm, "provider", "?"),
            strv(vm, "image", "?"),
        ));
    }
    let nw = rows.iter().map(|r| r.0.len()).max().unwrap_or(4).max(4);
    let lw = rows.iter().map(|r| r.1.len()).max().unwrap_or(5).max(5);
    let sw = rows.iter().map(|r| r.2.len()).max().unwrap_or(7).max(5);
    let pw = rows.iter().map(|r| r.3.len()).max().unwrap_or(8).max(8);
    let labeled = rows.iter().any(|r| !r.1.is_empty());
    let mut out = format!(
        "{:nw$}  {}{:sw$}  {:pw$}  IMAGE\n",
        "NAME",
        if labeled {
            format!("{:lw$}  ", "LABEL")
        } else {
            String::new()
        },
        "STATE",
        "PROVIDER"
    );
    for (id, label, state, provider, image) in rows {
        out.push_str(&format!(
            "{:nw$}  {}{:sw$}  {:pw$}  {}\n",
            id,
            if labeled {
                format!("{:lw$}  ", label)
            } else {
                String::new()
            },
            state,
            provider,
            image
        ));
    }
    if let Some(plan) = response
        .get("limits")
        .and_then(|x| x.get("planId"))
        .and_then(Value::as_str)
    {
        out.push_str(&format!("{} machines on the {} plan\n", vms.len(), plan));
    }
    ctx.print(out.trim_end())?;
    Ok(Some(0))
}

fn run_vm_status(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let id = one_id(args, "Usage: cmux vm status <id>")?;
    let response = ctx.rpc("vm.status", json!({"id": id}))?;
    if ctx.json {
        ctx.emit(&response)?;
    } else {
        ctx.print(format!(
            "{}  [{}] {}\nimage: {}",
            strv(&response, "id", &id),
            strv(&response, "provider", "?"),
            strv(&response, "status", "unknown"),
            strv(&response, "image", "?")
        ))?;
    }
    Ok(Some(0))
}

fn run_vm_stats(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let id = one_id(args, "Usage: cmux vm stats <id>")?;
    let response = ctx.rpc("vm.stats", json!({"id": id}))?;
    if ctx.json {
        ctx.emit(&response)?;
    } else {
        ctx.print(format_stats(&id, &response))?;
    }
    Ok(Some(0))
}

fn run_vm_resize(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    if args.iter().any(|x| x == "--help" || x == "-h") {
        ctx.print("Usage: cmux vm resize <id> [--cpu <vCPUs>] [--memory <GiB>] [--disk <GiB>]")?;
        return Ok(Some(0));
    }
    let mut id = None;
    let mut cpu = None;
    let mut memory = None;
    let mut disk = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--cpu" => {
                cpu = Some(next(args, &mut i)?);
            }
            "--memory" => {
                memory = Some(next(args, &mut i)?);
            }
            "--disk" => {
                disk = Some(next(args, &mut i)?);
            }
            x if !x.starts_with('-') && id.is_none() => id = Some(x.to_string()),
            _ => {
                return Err(CliError::usage(
                    "Usage: cmux vm resize <id> [--cpu <vCPUs>] [--memory <GiB>] [--disk <GiB>]",
                ));
            }
        }
        i += 1;
    }
    let id = id.ok_or_else(|| {
        CliError::usage(
            "Usage: cmux vm resize <id> [--cpu <vCPUs>] [--memory <GiB>] [--disk <GiB>]",
        )
    })?;
    if cpu.is_none() && memory.is_none() && disk.is_none() {
        return Err(CliError::usage("vm resize requires at least one resource"));
    }
    let mut p = Map::new();
    p.insert("id".into(), json!(id));
    if let Some(v) = cpu {
        let n: i64 = v.parse().map_err(|_| CliError::usage("CPU must be 1-32"))?;
        if !(1..=32).contains(&n) {
            return Err(CliError::usage("CPU must be 1-32"));
        }
        p.insert("cpu".into(), json!(n));
    }
    if let Some(v) = memory {
        p.insert("memory_mb".into(), json!(parse_gib(&v, 4, 64)? * 1024));
    }
    if let Some(v) = disk {
        p.insert("storage_mb".into(), json!(parse_gib(&v, 4, 256)? * 1024));
    }
    let response = ctx.rpc("vm.resize", Value::Object(p))?;
    if ctx.json {
        ctx.emit(&response)?;
    } else {
        ctx.print(format!(
            "OK {} cpu={} memory={} GiB disk={} GiB",
            id,
            numstr(&response, "cpus"),
            mbstr(&response, "memory_total_mb"),
            mbstr(&response, "disk_total_mb")
        ))?;
    }
    Ok(Some(0))
}

fn run_vm_rename(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let clear = args.iter().any(|x| x == "--clear");
    let pos: Vec<&String> = args.iter().filter(|x| !x.starts_with('-')).collect();
    if pos.is_empty() || (!clear && pos.len() < 2) {
        return Err(CliError::usage(
            "Usage: cmux vm rename <id> <new-label> | cmux vm rename <id> --clear",
        ));
    }
    let id = pos[0].to_string();
    let mut p = json!({"id": id});
    if !clear {
        p["display_name"] = json!(
            pos[1..]
                .iter()
                .map(|x| x.as_str())
                .collect::<Vec<_>>()
                .join(" ")
        );
    }
    let response = ctx.rpc("vm.rename", p)?;
    if ctx.json {
        ctx.emit(&response)?;
    } else if let Some(name) = response
        .get("displayName")
        .and_then(Value::as_str)
        .filter(|x| !x.is_empty())
    {
        ctx.print(format!("{} is now labeled “{}”", id, name))?;
    } else {
        ctx.print(format!("{} label cleared", id))?;
    }
    Ok(Some(0))
}

fn run_vm_lifecycle(ctx: &Context, action: &str, args: &[String]) -> Result<Option<i32>> {
    let id = one_id(args, &format!("Usage: cmux vm {} <id>", action))?;
    let response = ctx.rpc(&format!("vm.{}", action), json!({"id": id}))?;
    if ctx.json {
        ctx.emit(&response)?;
    } else {
        let s = strv(&response, "status", "?");
        ctx.print(if action == "pause" {
            format!(
                "OK {} paused (status={}); `cmux vm resume {}` wakes it",
                id, s, id
            )
        } else {
            format!("OK {} resumed (status={})", id, s)
        })?;
    }
    Ok(Some(0))
}

fn run_snapshot(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    if let Some(op) = args.first().map(|x| x.to_ascii_lowercase()) {
        if op == "ls" || op == "list" {
            let id = one_id(&args[1..], "Usage: cmux vm snapshot ls <machine>")?;
            let r = ctx.rpc("vm.snapshot_list", json!({"id": id}))?;
            if ctx.json {
                ctx.emit(&r)?;
            } else {
                let a = r
                    .get("snapshots")
                    .and_then(Value::as_array)
                    .cloned()
                    .unwrap_or_default();
                if a.is_empty() {
                    ctx.print("no snapshots")?;
                } else {
                    for s in a {
                        ctx.print(format!(
                            "{}\t{}\t{}",
                            strv(&s, "id", "?"),
                            strv(&s, "created_at", strv(&s, "createdAt", "-").as_str()),
                            strv(&s, "name", "-")
                        ))?;
                    }
                }
            }
            return Ok(Some(0));
        }
        if op == "rm" || op == "delete" {
            if args.len() != 3 {
                return Err(CliError::usage(
                    "Usage: cmux vm snapshot rm <machine> <snapshot-id>",
                ));
            }
            let r = ctx.rpc(
                "vm.snapshot_delete",
                json!({"id":args[1],"snapshot_id":args[2]}),
            )?;
            if ctx.json {
                ctx.emit(&r)?;
            } else {
                ctx.print(format!("OK deleted {} from {}", args[2], args[1]))?;
            }
            return Ok(Some(0));
        }
    }
    let mut name = None;
    let mut id = None;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--name" => name = Some(next(args, &mut i)?),
            x if !x.starts_with('-') && id.is_none() => id = Some(x.to_string()),
            _ => {
                return Err(CliError::usage(
                    "Usage: cmux vm snapshot <id> [--name <name>]",
                ));
            }
        };
        i += 1;
    }
    let id = id.ok_or_else(|| CliError::usage("Usage: cmux vm snapshot <id> [--name <name>]"))?;
    let mut p = json!({"id":id});
    if let Some(n) = name {
        p["name"] = json!(n);
    }
    let r = ctx.rpc("vm.snapshot", p)?;
    if ctx.json {
        ctx.emit(&r)?;
    } else {
        ctx.print(format!(
            "OK snapshot={}",
            strv(&r, "snapshot_id", strv(&r, "id", "?").as_str())
        ))?;
    }
    Ok(Some(0))
}

fn run_vm_fork(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let (id, name, detach) = parse_create_args(
        args,
        "Usage: cmux vm fork <id> [--name <name>] [--detach|-d]",
    )?;
    let mut p = json!({"id":id,"idempotency_key":uuid::Uuid::new_v4().to_string()});
    if let Some(n) = name {
        p["name"] = json!(n);
    }
    let r = ctx.rpc("vm.fork", p)?;
    if ctx.json {
        ctx.emit(&r)?;
    } else {
        let nid = strv(&r, "id", "?");
        if detach {
            ctx.print(format!(
                "OK {}\n  provider: {}\n  image:    {}\n  snapshot: {}",
                nid,
                strv(&r, "provider", "?"),
                strv(&r, "image", "?"),
                strv(&r, "snapshot_id", "native fork")
            ))?;
        } else {
            ctx.print(format!("Forked Cloud VM {}", nid))?;
        }
    }
    Ok(Some(0))
}
fn run_vm_restore(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let id = one_id(
        args,
        "Usage: cmux vm restore <snapshot-id> [--provider <provider>] [--detach|-d]",
    )?;
    let r = ctx.rpc(
        "vm.restore",
        json!({"snapshot_id":id,"idempotency_key":uuid::Uuid::new_v4().to_string()}),
    )?;
    if ctx.json {
        ctx.emit(&r)?;
    } else {
        ctx.print(format!("Restored Cloud VM {}", strv(&r, "id", "?")))?;
    }
    Ok(Some(0))
}
fn run_vm_rm(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let id = one_id(args, "Usage: cmux vm rm <id>")?;
    let r = ctx.rpc("vm.destroy", json!({"id":id}))?;
    if ctx.json {
        ctx.emit(&json!({"ok":true,"id":id,"response":r}))?;
    } else {
        ctx.print(format!("OK {}", id))?;
    }
    Ok(Some(0))
}
fn run_promote_template(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let id = one_id(args, "Usage: cmux vm promote-template <id>")?;
    let name = format!("template-{}-{}", &id[..id.len().min(12)], chrono_seconds());
    let r = ctx.rpc("vm.snapshot", json!({"id":id,"name":name}))?;
    if ctx.json {
        ctx.emit(&r)?;
    } else {
        ctx.print(format!(
            "OK template={}",
            strv(&r, "snapshot_id", strv(&r, "id", "?").as_str())
        ))?;
    }
    Ok(Some(0))
}
fn run_base(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let action = args.first().map(String::as_str).unwrap_or("open");
    let m = if action == "reset" {
        "vm.base_reset"
    } else {
        "vm.base_open"
    };
    let r = ctx.rpc(m, json!({}))?;
    if ctx.json {
        ctx.emit(&r)?;
    } else {
        ctx.print(format!("OK {}", action))?;
    }
    Ok(Some(0))
}

fn run_vm_self(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    if args.iter().any(|x| x == "--help" || x == "-h") {
        ctx.print("Usage: cmux vm self <machine> [<path>] [--json]")?;
        return Ok(Some(0));
    }
    let a: Vec<&String> = args.iter().filter(|x| *x != "--json").collect();
    if a.is_empty() || a.len() > 2 {
        return Err(CliError::usage(
            "Usage: cmux vm self <machine> [<path>] [--json]",
        ));
    }
    let p = a.get(1).map(|x| x.trim_matches('/')).unwrap_or("");
    let r = ctx.rpc("vm.reflection", json!({"id":a[0],"path":p}))?;
    if ctx.json || !p.is_empty() {
        ctx.emit(&r)?;
    } else {
        let b = r.get("reflection").unwrap_or(&r);
        ctx.print(format!(
            "name\t{}\nmachine\t{}\t{}\nowner\t{}\nteam\t{}",
            strv(b, "name", strv(b, "display_name", "?").as_str()),
            strv(b, "vm_id", strv(b, "id", "?").as_str()),
            strv(b, "status", "?"),
            b.get("owner")
                .and_then(|o| o.get("email"))
                .and_then(Value::as_str)
                .unwrap_or("?"),
            strv(b, "team_id", "-")
        ))?;
    }
    Ok(Some(0))
}

fn run_sidebar(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let a: Vec<&String> = args
        .iter()
        .filter(|x| *x != "--sidebar" && *x != "--json")
        .collect();
    let action = a.first().map(|x| x.as_str()).unwrap_or("list");
    let mut p = json!({"sidebar":true,"action":action});
    if let Some(x) = a.get(1) {
        p["node_id"] = json!(x);
    }
    if let Some(x) = a.get(2) {
        p["target_id"] = json!(x);
    }
    let r = ctx.rpc("vm.tree", p)?;
    if ctx.json {
        ctx.emit(&r)?;
    } else {
        print_rows(
            ctx,
            r.get("rows")
                .and_then(Value::as_array)
                .unwrap_or(&Vec::new()),
            0,
        )?;
    }
    Ok(Some(0))
}
fn print_rows(ctx: &Context, rows: &[Value], depth: usize) -> Result<()> {
    for row in rows {
        let pin = if row.get("pinned").and_then(Value::as_bool).unwrap_or(false) {
            "📌 "
        } else {
            ""
        };
        ctx.print(format!(
            "{}{}  {}",
            "  ".repeat(depth),
            format!("{}{}", pin, strv(row, "title", "")),
            strv(row, "id", "")
        ))?;
        if let Some(c) = row.get("children").and_then(Value::as_array) {
            print_rows(ctx, c, depth + 1)?;
        }
    }
    Ok(())
}

fn run_domains(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let sub = args.first().map(|x| x.as_str()).unwrap_or("list");
    let a = &args[1..];
    match sub {
        "list" | "ls" => {
            let r = ctx.rpc("vm.publication_list", json!({}))?;
            if ctx.json {
                ctx.emit(
                    &json!({"publications":r.get("publications").cloned().unwrap_or(json!([]))}),
                )?;
            } else {
                for x in r
                    .get("publications")
                    .and_then(Value::as_array)
                    .unwrap_or(&Vec::new())
                {
                    ctx.print(format!(
                        "https://{}\nid: {}\nvm: {}:{}\naccess: {}\nstate: {}",
                        strv(x, "hostname", "?"),
                        strv(x, "id", "?"),
                        strv(x, "vmId", "?"),
                        strv(x, "port", "?"),
                        strv(x, "accessMode", "?"),
                        strv(x, "state", "unknown")
                    ))?;
                }
            }
        }
        "zones" | "custom" => {
            let r = ctx.rpc("vm.domain_list", json!({}))?;
            if ctx.json {
                ctx.emit(&r)?;
            } else {
                for x in r
                    .get("domains")
                    .and_then(Value::as_array)
                    .unwrap_or(&Vec::new())
                {
                    ctx.print(format!(
                        "{}\t{}",
                        strv(x, "name", "?"),
                        strv(x, "status", "?")
                    ))?;
                }
            }
        }
        "verify" => {
            let d = one_id(a, "Usage: cmux cloud domains verify <domain>")?;
            let r = ctx.rpc("vm.domain_verify", json!({"name":d}))?;
            emit_domain(ctx, r)?;
        }
        "publish" => domain_publish(ctx, a)?,
        "access" => domain_access(ctx, a)?,
        "grant" | "ungrant" | "grants" => domain_grant(ctx, sub, a)?,
        "rm" | "remove" | "delete" => {
            let id = one_id(a, DOMAIN_USAGE)?;
            let r = ctx.rpc("vm.publication_delete", json!({"id":id}))?;
            if ctx.json {
                ctx.emit(&r)?;
            } else {
                ctx.print(format!("Removed publication {}.", id))?;
            }
        }
        "help" | "--help" | "-h" => ctx.print(DOMAIN_USAGE)?,
        _ => return Err(CliError::usage(DOMAIN_USAGE)),
    };
    Ok(Some(0))
}

fn domain_publish(ctx: &Context, a: &[String]) -> Result<()> {
    let mut vm = None;
    let mut port = None;
    let mut domain = None;
    let mut access = "personal".to_string();
    let mut team = None;
    let mut org = None;
    let mut yes = false;
    let mut i = 0;
    while i < a.len() {
        match a[i].as_str() {
            "--domain" => domain = Some(next(a, &mut i)?),
            "--access" => access = next(a, &mut i)?,
            "--team" => team = Some(next(a, &mut i)?),
            "--org-slug" => org = Some(next(a, &mut i)?),
            "--yes" => yes = true,
            x if !x.starts_with('-') && vm.is_none() => vm = Some(x.to_string()),
            x if !x.starts_with('-') && port.is_none() => {
                port = Some(x.parse::<i32>().map_err(|_| CliError::usage(DOMAIN_USAGE))?)
            }
            _ => return Err(CliError::usage(DOMAIN_USAGE)),
        };
        i += 1;
    }
    let port = port.ok_or_else(|| CliError::usage(DOMAIN_USAGE))?;
    if !(1..=65535).contains(&port) {
        return Err(CliError::usage("port must be 1-65535"));
    }
    if access == "public" && !yes && ctx.non_interactive {
        return Err(CliError::usage(
            "public access requires --yes in non-interactive mode",
        ));
    }
    let mut p = json!({"vmId":vm.ok_or_else(||CliError::usage(DOMAIN_USAGE))?,"port":port});
    if access != "personal" {
        p["accessMode"] = json!(access);
    }
    if let Some(x) = domain {
        p["hostname"] = json!(x);
    }
    if let Some(x) = team {
        p["teamId"] = json!(x);
    }
    if let Some(x) = org {
        p["organizationSlug"] = json!(x);
    }
    let r = ctx.rpc("vm.publication_create", p)?;
    if ctx.json {
        ctx.emit(&r)?;
    } else {
        ctx.print(format!("Published {}", strv(&r, "hostname", "?")))?;
    }
    Ok(())
}
fn domain_access(ctx: &Context, a: &[String]) -> Result<()> {
    if a.len() < 2 {
        return Err(CliError::usage(DOMAIN_USAGE));
    }
    let mut p = json!({"id":a[0],"accessMode":a[1]});
    if let Some(i) = a.iter().position(|x| x == "--team") {
        if let Some(v) = a.get(i + 1) {
            p["teamId"] = json!(v);
        }
    }
    let r = ctx.rpc("vm.publication_update", p)?;
    if ctx.json {
        ctx.emit(&r)?;
    } else {
        ctx.print(format!("Updated {} access to {}", a[0], a[1]))?;
    }
    Ok(())
}
fn domain_grant(ctx: &Context, sub: &str, a: &[String]) -> Result<()> {
    if a.is_empty() {
        return Err(CliError::usage(DOMAIN_USAGE));
    }
    let mut p = json!({"id":a[0]});
    if sub != "grants" {
        if a.len() < 2 {
            return Err(CliError::usage(DOMAIN_USAGE));
        }
        p["email"] = json!(a[1]);
    }
    if let Some(i) = a.iter().position(|x| x == "--expires") {
        if let Some(v) = a.get(i + 1) {
            p["expiresAt"] = json!(v);
        }
    }
    let r = ctx.rpc(&format!("vm.publication_{}", sub), p)?;
    ctx.emit(&r)?;
    Ok(())
}

fn run_vpn(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let sub = args.first().map(|x| x.as_str()).unwrap_or("status");
    match sub {
        "status" => {
            let r = ctx.rpc("vm.tunnel_status", json!({}))?;
            if ctx.json {
                ctx.emit(&r)?;
            } else {
                ctx.print(format!(
                    "Terminal tunnel: {} (user-space WireGuard)\nSystem-wide tunnel: {}",
                    if r.get("terminal_tunnel")
                        .and_then(|x| x.get("hub_running"))
                        .and_then(Value::as_bool)
                        .unwrap_or(false)
                    {
                        "up"
                    } else {
                        "idle"
                    },
                    if r.get("backend").and_then(Value::as_str) == Some("network-extension") {
                        strv(&r, "tunnel_state", "off")
                    } else {
                        "unavailable in this build".to_string()
                    }
                ))?;
            }
        }
        "up" | "on" => {
            let s = ctx.rpc("vm.tunnel_status", json!({}))?;
            if s.get("backend").and_then(Value::as_str) != Some("network-extension") {
                return Err(CliError::usage(
                    "This cmux build has no signed Network Extension.",
                ));
            }
            let r = ctx.rpc("vm.tunnel_up", json!({}))?;
            if ctx.json {
                ctx.emit(&r)?;
            } else {
                ctx.print("Tunnel is up.")?;
            }
        }
        "down" | "off" => {
            let r = ctx.rpc("vm.tunnel_down", json!({}))?;
            if ctx.json {
                ctx.emit(&r)?;
            } else {
                ctx.print("Tunnel is down.")?;
            }
        }
        "revoke" => {
            let r = ctx.rpc("vm.tunnel_revoke", json!({}))?;
            if ctx.json {
                ctx.emit(&r)?;
            } else {
                ctx.print("This Mac can no longer access your Cloud VM network.")?;
            }
        }
        _ => return Err(CliError::usage("Usage: cmux vpn <up|down|status|revoke>")),
    };
    Ok(Some(0))
}

fn run_remotes(ctx: &Context, args: &[String]) -> Result<Option<i32>> {
    let sub = args.first().map(|x| x.as_str()).unwrap_or("list");
    let a = &args[1..];
    match sub {
        "list" | "ls" => {
            let r = ctx.rpc("remotes.list", json!({}))?;
            if ctx.json {
                ctx.emit(&r)?;
            } else {
                for x in r
                    .get("remotes")
                    .and_then(Value::as_array)
                    .unwrap_or(&Vec::new())
                {
                    ctx.print(format!(
                        "{}  {}  {}",
                        strv(x, "name", "?"),
                        strv(x, "deviceId", "?"),
                        strv(x, "routes", "")
                    ))?;
                }
            }
        }
        "add" => {
            let name = a.first().ok_or_else(|| CliError::usage(REMOTES_USAGE))?;
            let routes = all_options(a, "--route")?;
            if routes.is_empty() {
                return Err(CliError::usage(
                    "remotes add requires at least one --route host:port",
                ));
            }
            for r in &routes {
                validate_route(r)?;
            }
            let mut p = json!({"name":name,"routes":routes});
            if let Some(t) = option(a, "--tag") {
                p["tag"] = json!(t);
            }
            let r = ctx.rpc("remotes.add", p)?;
            if ctx.json {
                ctx.emit(&r)?;
            } else {
                ctx.print(format!(
                    "OK {}\n  deviceId: {}",
                    name,
                    strv(&r, "deviceId", "?")
                ))?;
            }
        }
        "remove" | "rm" | "delete" => {
            let target = a
                .iter()
                .find(|x| !x.starts_with('-'))
                .ok_or_else(|| CliError::usage(REMOTES_USAGE))?;
            let r = ctx.rpc("remotes.remove", json!({"target":target}))?;
            if ctx.json {
                ctx.emit(&r)?;
            } else {
                ctx.print(format!("OK removed {}", target))?;
            }
        }
        "help" | "--help" | "-h" => ctx.print(REMOTES_USAGE)?,
        _ => return Err(CliError::usage(REMOTES_USAGE)),
    };
    Ok(Some(0))
}

fn one_id(args: &[String], usage: &str) -> Result<String> {
    if args.len() != 1 || args[0].starts_with('-') {
        Err(CliError::usage(usage))
    } else {
        Ok(args[0].clone())
    }
}
fn next(args: &[String], i: &mut usize) -> Result<String> {
    *i += 1;
    args.get(*i)
        .cloned()
        .ok_or_else(|| CliError::usage("missing option value"))
}
fn option(args: &[String], name: &str) -> Option<String> {
    args.windows(2).find(|w| w[0] == name).map(|w| w[1].clone())
}
fn all_options(args: &[String], name: &str) -> Result<Vec<String>> {
    let mut out = Vec::new();
    let mut i = 0;
    while i < args.len() {
        if args[i] == name {
            out.push(
                args.get(i + 1)
                    .ok_or_else(|| CliError::usage("missing option value"))?
                    .clone(),
            );
            i += 1;
        }
        i += 1;
    }
    Ok(out)
}
fn parse_gib(raw: &str, min: i64, max: i64) -> Result<i64> {
    let x = raw.to_ascii_lowercase();
    let n = x
        .trim_end_matches("gib")
        .trim_end_matches("gb")
        .trim_end_matches('g');
    let v: i64 = n
        .parse()
        .map_err(|_| CliError::usage("size must be whole GiB"))?;
    if (min..=max).contains(&v) {
        Ok(v)
    } else {
        Err(CliError::usage("size out of range"))
    }
}
fn parse_create_args(args: &[String], usage: &str) -> Result<(String, Option<String>, bool)> {
    let mut id = None;
    let mut name = None;
    let mut detach = false;
    let mut i = 0;
    while i < args.len() {
        match args[i].as_str() {
            "--name" => {
                name = Some(
                    args.get(i + 1)
                        .ok_or_else(|| CliError::usage(usage))?
                        .clone(),
                )
            }
            "--detach" | "-d" => detach = true,
            x if !x.starts_with('-') && id.is_none() => id = Some(x.to_string()),
            _ => return Err(CliError::usage(usage)),
        };
        i += 1;
    }
    Ok((id.ok_or_else(|| CliError::usage(usage))?, name, detach))
}
fn validate_route(raw: &str) -> Result<()> {
    let t = raw.trim();
    let (host, port) = if let Some(rest) = t.strip_prefix('[') {
        let (h, p) = rest
            .split_once("]:")
            .ok_or_else(|| CliError::usage("route must be host:port"))?;
        (h, p)
    } else {
        t.rsplit_once(':')
            .ok_or_else(|| CliError::usage("route must be host:port"))?
    };
    let n: u16 = port
        .parse()
        .map_err(|_| CliError::usage("route port must be 1-65535"))?;
    if n == 0 {
        return Err(CliError::usage("route port must be 1-65535"));
    }
    let l = host.trim_matches(['[', ']']);
    if l == "localhost"
        || l == "127.0.0.1"
        || l == "::1"
        || l.parse::<IpAddr>()
            .map(|ip| ip.is_loopback())
            .unwrap_or(false)
    {
        return Err(CliError::usage("refusing loopback remote route"));
    }
    Ok(())
}
fn strv(v: &Value, key: &str, default: &str) -> String {
    v.get(key)
        .and_then(Value::as_str)
        .unwrap_or(default)
        .to_string()
}
fn nonempty(s: String) -> Option<String> {
    if s.is_empty() { None } else { Some(s) }
}
fn numstr(v: &Value, key: &str) -> String {
    v.get(key)
        .map(|x| {
            if let Some(n) = x.as_i64() {
                n.to_string()
            } else {
                x.to_string()
            }
        })
        .unwrap_or_else(|| "-".into())
}
fn mbstr(v: &Value, key: &str) -> String {
    v.get(key)
        .and_then(Value::as_i64)
        .map(|n| (n / 1024).to_string())
        .unwrap_or_else(|| "-".into())
}
fn format_stats(id: &str, v: &Value) -> String {
    format!(
        "{} cpu={} memory={} disk={}",
        id,
        numstr(v, "cpu"),
        numstr(v, "memory_mb"),
        numstr(v, "disk_mb")
    )
}
fn chrono_seconds() -> u64 {
    use std::time::{SystemTime, UNIX_EPOCH};
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|d| d.as_secs())
        .unwrap_or(0)
}

fn emit_domain(ctx: &Context, v: Value) -> Result<()> {
    if ctx.json {
        ctx.emit(&v)
    } else {
        ctx.print(
            v.get("domain")
                .map(|d| format!("{}\t{}", strv(d, "name", "?"), strv(d, "status", "?")))
                .unwrap_or_default(),
        )
    }
}
