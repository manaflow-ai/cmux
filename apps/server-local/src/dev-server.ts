import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { startServer } from "./server";

const __dirname = path.dirname(fileURLToPath(import.meta.url));

await startServer({
  port: parseInt(process.env.PORT || "9776"),
  publicPath: path.join(__dirname, "../../client/dist"),
});
