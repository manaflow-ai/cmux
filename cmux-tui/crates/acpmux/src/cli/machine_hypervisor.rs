//! `acpmux machine hypervisor serve | apply | ls`: the host agent (`crate::hypervisor`).
//! No daemon: the host agent is its own process (a systemd unit on the host).

use crate::cli::command_host::{HypervisorCmd, HypervisorDriverKind, HypervisorOpts};
use crate::cli::output::print_json;
use crate::hypervisor::HypervisorDriver;
use crate::hypervisor::libvirt::{LibvirtConfig, LibvirtDriver, ProcessRunner};
use crate::hypervisor::pods::PodsDriver;
use crate::hypervisor::serve::{HostAgent, action_line};
use crate::hypervisor::source::{Command, SpoolSource};
use anyhow::{Context, Result};
use std::io::Read;
use std::path::PathBuf;

fn now_ms() -> u64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_millis() as u64)
        .unwrap_or(0)
}

fn state_dir(opts: &HypervisorOpts) -> PathBuf {
    opts.state_dir.clone().unwrap_or_else(|| crate::config::home().join("hypervisor"))
}

/// The state dir, made owner-only whatever the umask, as acpmux makes its own (an existing one
/// wider than that is refused with the `chmod` that fixes it): it holds the leases and the spool, and a pod's `HOME` under it
/// boots an acpmux daemon that refuses a writable ancestor.
fn private_state_dir(opts: &HypervisorOpts) -> Result<PathBuf> {
    let dir = state_dir(opts);
    crate::config::private_state_dir(&dir)?;
    Ok(dir)
}

fn libvirt(opts: &HypervisorOpts) -> LibvirtConfig {
    let mut config = LibvirtConfig::new(state_dir(opts).join("images"));
    config.connect = opts.connect.clone();
    config
}

/// The slot driver `--driver` names; `config` is libvirt's, unused by pods.
fn driver(opts: &HypervisorOpts, config: LibvirtConfig) -> Box<dyn HypervisorDriver> {
    match opts.driver {
        HypervisorDriverKind::Libvirt => Box::new(LibvirtDriver::new(config, ProcessRunner)),
        HypervisorDriverKind::Pods => {
            let dir = opts.pods_dir.clone().unwrap_or_else(|| state_dir(opts).join("pods"));
            let mut pods = cmux_pool_pod::slots::PodSlots::new(
                cmux_pool_pod::slots::ProcessRunner,
                dir.to_string_lossy(),
            );
            if let Some(init) = &opts.pod_init {
                pods = pods.with_init(init, opts.pod_init_args.clone(), Vec::new());
            }
            Box::new(PodsDriver::new(
                pods.with_pass_env(opts.pod_env.clone()).with_binds(opts.pod_bind.clone()),
            ))
        }
    }
}

pub async fn run(cmd: HypervisorCmd, json_out: bool) -> Result<()> {
    tokio::task::spawn_blocking(move || run_blocking(cmd, json_out)).await?
}

fn run_blocking(cmd: HypervisorCmd, json_out: bool) -> Result<()> {
    match cmd {
        HypervisorCmd::Serve { opts, base_image, network, template, interval_secs, once } => {
            let dir = private_state_dir(&opts)?;
            let mut config = libvirt(&opts);
            config.base_image = base_image;
            config.network = network;
            if let Some(path) = template {
                config.template = std::fs::read_to_string(&path)
                    .with_context(|| format!("read template {}", path.display()))?;
            }
            let driver = driver(&opts, config);
            let source = SpoolSource::new(dir.join("spool"));
            let mut agent = HostAgent::open(driver, source, dir)?;
            loop {
                match agent.tick(now_ms()) {
                    Ok(tick) => {
                        if json_out {
                            print_json(&serde_json::to_value(&tick)?);
                        } else {
                            for a in &tick.applied {
                                match &a.outcome.error {
                                    None => println!("{}: done", a.id),
                                    Some(e) => println!("{}: failed: {e}", a.id),
                                }
                            }
                            tick.enforced.iter().for_each(|e| println!("{}", action_line(e)));
                        }
                    }
                    Err(e) if !once => eprintln!("hypervisor pass failed: {e:#}"),
                    Err(e) => return Err(e),
                }
                if once {
                    return Ok(());
                }
                std::thread::sleep(std::time::Duration::from_secs(interval_secs.max(1)));
            }
        }
        HypervisorCmd::Apply { opts, id } => {
            let mut text = String::new();
            std::io::stdin().read_to_string(&mut text)?;
            let command: Command =
                serde_json::from_str(&text).context("parse the command on stdin")?;
            let dir = private_state_dir(&opts)?;
            let env = SpoolSource::new(dir.join("spool")).submit(command, id, now_ms())?;
            if json_out {
                print_json(&serde_json::to_value(&env)?);
            } else {
                println!("queued {}", env.id);
            }
            Ok(())
        }
        HypervisorCmd::Ls { opts } => {
            let dir = private_state_dir(&opts)?;
            let driver = driver(&opts, libvirt(&opts));
            let book = crate::hypervisor::lease::LeaseBook::load(&dir.join("leases.json"))?;
            let slots = driver.list()?;
            let rows: Vec<serde_json::Value> = slots
                .iter()
                .map(|s| {
                    serde_json::json!({
                        "slot": s.name,
                        "state": s.state,
                        "lease": book.slots.get(&s.name),
                    })
                })
                .collect();
            if json_out {
                print_json(&serde_json::Value::Array(rows));
            } else if slots.is_empty() {
                println!("no cmux VMs on this host");
            } else {
                for s in &slots {
                    let lease =
                        if book.slots.contains_key(&s.name) { "" } else { "  (no lease: orphan)" };
                    println!("{}  {:?}{lease}", s.name, s.state);
                }
            }
            Ok(())
        }
    }
}

#[cfg(all(test, unix))]
mod tests {
    use super::*;
    use std::os::unix::fs::PermissionsExt as _;

    fn opts(dir: &std::path::Path) -> HypervisorOpts {
        HypervisorOpts {
            state_dir: Some(dir.to_path_buf()),
            connect: None,
            driver: HypervisorDriverKind::Pods,
            pods_dir: None,
            pod_init: None,
            pod_init_args: Vec::new(),
            pod_env: Vec::new(),
            pod_bind: Vec::new(),
        }
    }

    #[test]
    fn the_state_dir_is_made_owner_only_and_a_wider_one_refused() {
        // A pod's HOME sits under the state dir; its acpmux daemon refuses a writable ancestor,
        // so a state dir made under umask 002 (drwxrwxr-x) left every pod's init dead.
        let base = tempfile::tempdir().unwrap();
        std::fs::set_permissions(base.path(), std::fs::Permissions::from_mode(0o700)).unwrap();
        let dir = base.path().join("hypervisor");
        assert_eq!(private_state_dir(&opts(&dir)).unwrap(), dir);
        let mode = std::fs::metadata(&dir).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o700, "{mode:o}");

        let wide = base.path().join("wide");
        std::fs::create_dir(&wide).unwrap();
        std::fs::set_permissions(&wide, std::fs::Permissions::from_mode(0o775)).unwrap();
        let err = private_state_dir(&opts(&wide)).unwrap_err().to_string();
        assert!(err.contains("chmod 700"), "{err}");
    }
}
