import * as fs from "node:fs";
import * as path from "node:path";
import * as os from "node:os";

export type LogLevel = "debug" | "info" | "warn" | "error";

/**
 * FileLogger - Logs to file and optionally to console based on NODE_ENV
 * 
 * Behavior:
 * - Production (NODE_ENV=production): Logs only to file
 * - Development (NODE_ENV!=production): Logs to both file and console
 * 
 * Log files are stored in ~/.cmux/logs/
 */
export class FileLogger {
  private logDir: string;
  private logFile: string;
  private writeStream: fs.WriteStream | null = null;

  constructor(logFileName: string) {
    // Use a dedicated logs directory in the home folder
    this.logDir = path.join(os.homedir(), ".cmux", "logs");
    this.logFile = path.join(this.logDir, logFileName);
    this.ensureLogDirectory();
    this.initializeStream();
  }

  private ensureLogDirectory(): void {
    if (!fs.existsSync(this.logDir)) {
      fs.mkdirSync(this.logDir, { recursive: true });
    }
  }

  private initializeStream(): void {
    this.writeStream = fs.createWriteStream(this.logFile, {
      flags: "a", // append mode
      encoding: "utf8",
      highWaterMark: 0, // Disable buffering for immediate writes
    });
  }

  private formatMessage(level: LogLevel, message: string, ...args: any[]): string {
    const timestamp = new Date().toISOString();
    const formattedArgs = args.length > 0 ? " " + args.map(arg => 
      typeof arg === "object" ? JSON.stringify(arg, null, 2) : String(arg)
    ).join(" ") : "";
    return `[${timestamp}] [${level.toUpperCase()}] ${message}${formattedArgs}\n`;
  }

  debug(message: string, ...args: any[]): void {
    if (process.env.DEBUG) {
      this.write("debug", message, ...args);
    }
  }

  info(message: string, ...args: any[]): void {
    this.write("info", message, ...args);
  }

  warn(message: string, ...args: any[]): void {
    this.write("warn", message, ...args);
  }

  error(message: string, ...args: any[]): void {
    this.write("error", message, ...args);
  }

  private write(level: LogLevel, message: string, ...args: any[]): void {
    const formattedMessage = this.formatMessage(level, message, ...args);
    
    if (process.env.NODE_ENV === "production") {
      // In production, use synchronous write to ensure data is written immediately
      try {
        fs.appendFileSync(this.logFile, formattedMessage);
      } catch (error) {
        // Fallback to stream if sync write fails
        if (this.writeStream && !this.writeStream.destroyed) {
          this.writeStream.write(formattedMessage);
        }
      }
    } else {
      // In development, log to both file and console
      if (this.writeStream && !this.writeStream.destroyed) {
        this.writeStream.write(formattedMessage);
      }
      
      const consoleMethod = level === "error" ? console.error : 
                           level === "warn" ? console.warn : 
                           console.log;
      consoleMethod(`[${level.toUpperCase()}]`, message, ...args);
    }
  }


  close(): void {
    if (this.writeStream && !this.writeStream.destroyed) {
      this.writeStream.end();
    }
  }
}

// Create logger instances for different modules
export const dockerLogger = new FileLogger("docker-vscode.log");
export const serverLogger = new FileLogger("server.log");
export const createLogger = (logFileName: string) => new FileLogger(logFileName);

// Register exit handlers to ensure logs are flushed
const closeAllLoggers = () => {
  dockerLogger.close();
  serverLogger.close();
};

process.on("exit", closeAllLoggers);
process.on("SIGINT", closeAllLoggers);
process.on("SIGTERM", closeAllLoggers);
process.on("uncaughtException", (error) => {
  serverLogger.error("Uncaught exception:", error);
  closeAllLoggers();
  process.exit(1);
});
process.on("unhandledRejection", (reason, promise) => {
  serverLogger.error("Unhandled rejection at:", promise, "reason:", reason);
  closeAllLoggers();
  process.exit(1);
});