import { env } from "@/lib/utils/www-env";
import { jwtVerify } from "jose";
import { z } from "zod";

const taskRunJwtSecret = new TextEncoder().encode(
  env.CMUX_TASK_RUN_JWT_SECRET
);

const TaskRunTokenPayloadSchema = z.object({
  taskRunId: z.string().min(1),
  teamId: z.string().min(1),
  userId: z.string().min(1),
});

export type TaskRunTokenPayload = z.infer<typeof TaskRunTokenPayloadSchema>;

export async function verifyTaskRunToken(
  token: string
): Promise<TaskRunTokenPayload> {
  const verification = await jwtVerify(token, taskRunJwtSecret);
  const parsed = TaskRunTokenPayloadSchema.safeParse(verification.payload);
  if (!parsed.success) {
    throw new Error("Invalid CMUX token payload");
  }

  return parsed.data;
}
