/** A provider call's failure: only the step, the status and a provider code, never a body or a key. */
export class DriverError extends Error {
  constructor(
    readonly code: string,
    message: string,
    /** True when retrying cannot help (configuration, authorization, a deleted VM). */
    readonly final: boolean
  ) {
    super(message)
  }
}

/** One root command's answer (cx-kvmz). */
export interface GuestExecResult {
  readonly exitCode: number
  readonly stdout: string
  readonly stderr: string
}
