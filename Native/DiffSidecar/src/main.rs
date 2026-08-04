use std::path::PathBuf;

#[cfg(feature = "benchmark")]
use cmux_diff_sidecar::benchmark;
use cmux_diff_sidecar::server::{self, ServerConfig};

#[tokio::main]
async fn main() {
    if let Err(message) = run().await {
        eprintln!("cmux-diff-sidecar: {message}");
        std::process::exit(1);
    }
}

async fn run() -> Result<(), String> {
    let mut args = std::env::args().skip(1);
    match args.next().as_deref() {
        #[cfg(feature = "http-server")]
        Some("serve") => {
            let mut root = None;
            let mut cmux = None;
            while let Some(argument) = args.next() {
                match argument.as_str() {
                    "--root" => root = args.next().map(PathBuf::from),
                    "--cmux" => cmux = args.next().map(PathBuf::from),
                    _ => return Err(format!("unexpected argument: {argument}")),
                }
            }
            let root = root.ok_or_else(|| "serve requires --root".to_owned())?;
            let cmux_executable = cmux.ok_or_else(|| "serve requires --cmux".to_owned())?;
            let executable_path = std::env::current_exe().map_err(|error| error.to_string())?;
            server::run(ServerConfig {
                root,
                cmux_executable,
                executable_path,
            })
            .await
        }
        Some("rpc") => {
            let mut root = None;
            let mut cmux = None;
            let mut process_group_ready = false;
            while let Some(argument) = args.next() {
                match argument.as_str() {
                    "--root" => root = args.next().map(PathBuf::from),
                    "--cmux" => cmux = args.next().map(PathBuf::from),
                    "--process-group-ready" => process_group_ready = true,
                    _ => return Err(format!("unexpected argument: {argument}")),
                }
            }
            let root = root.ok_or_else(|| "rpc requires --root".to_owned())?;
            let cmux_executable = cmux.ok_or_else(|| "rpc requires --cmux".to_owned())?;
            let executable_path = std::env::current_exe().map_err(|error| error.to_string())?;
            if process_group_ready {
                establish_rpc_process_group()?;
            }
            server::run_rpc(ServerConfig {
                root,
                cmux_executable,
                executable_path,
            })
            .await
        }
        Some("handshake") => {
            reject_remaining_arguments(&mut args)?;
            server::write_handshake_to_stdout().await
        }
        #[cfg(feature = "benchmark")]
        Some("benchmark") => {
            let sample_bytes = args
                .next()
                .map(|value| value.parse::<usize>())
                .transpose()
                .map_err(|error| error.to_string())?
                .unwrap_or(16 * 1024 * 1024);
            let iterations = args
                .next()
                .map(|value| value.parse::<usize>())
                .transpose()
                .map_err(|error| error.to_string())?
                .unwrap_or(20);
            reject_remaining_arguments(&mut args)?;
            let report = benchmark::run(sample_bytes, iterations)?;
            println!(
                "{}",
                serde_json::to_string_pretty(&report).map_err(|error| error.to_string())?
            );
            enforce_benchmark_budget(&report)?;
            Ok(())
        }
        _ => Err("usage: cmux-diff-sidecar <rpc|handshake>".to_owned()),
    }
}

fn establish_rpc_process_group() -> Result<(), String> {
    #[cfg(unix)]
    {
        rustix::process::setpgid(None, None).map_err(|error| error.to_string())?;
        eprintln!("cmux-diff-sidecar-process-group-ready");
        Ok(())
    }
    #[cfg(not(unix))]
    Err("process groups are unavailable on this platform".to_owned())
}

fn reject_remaining_arguments(args: &mut impl Iterator<Item = String>) -> Result<(), String> {
    if let Some(argument) = args.next() {
        return Err(format!("unexpected argument: {argument}"));
    }
    Ok(())
}

#[cfg(feature = "benchmark")]
fn enforce_benchmark_budget(report: &benchmark::BenchmarkReport) -> Result<(), String> {
    if let Some(maximum) = environment_number::<u128>("CMUX_DIFF_BENCH_MAX_MANIFEST_P95_US")?
        && report.manifest_decode_p95_micros > maximum
    {
        return Err(format!(
            "manifest decode p95 was {} us, budget is {maximum} us",
            report.manifest_decode_p95_micros
        ));
    }
    if let Some(minimum) = environment_number::<f64>("CMUX_DIFF_BENCH_MIN_READ_MIBPS")? {
        if !minimum.is_finite() || minimum < 0.0 {
            return Err(
                "CMUX_DIFF_BENCH_MIN_READ_MIBPS must be finite and non-negative".to_owned(),
            );
        }
        if report.sequential_read_mib_per_second < minimum {
            return Err(format!(
                "sequential read throughput was {:.1} MiB/s, budget is {minimum:.1} MiB/s",
                report.sequential_read_mib_per_second
            ));
        }
    }
    Ok(())
}

#[cfg(feature = "benchmark")]
fn environment_number<T>(name: &str) -> Result<Option<T>, String>
where
    T: std::str::FromStr,
    T::Err: std::fmt::Display,
{
    std::env::var(name)
        .ok()
        .map(|value| {
            value
                .parse::<T>()
                .map_err(|error| format!("invalid {name}: {error}"))
        })
        .transpose()
}
