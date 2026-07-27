use std::env;
use std::fs::File;
use std::path::Path;

use gl_generator::{Api, Fallbacks, GlobalGenerator, Profile, Registry};

fn main() {
    let output_directory = env::var("OUT_DIR").expect("OUT_DIR must be set by Cargo");
    let bindings_path = Path::new(&output_directory).join("gl_bindings.rs");
    let mut bindings = File::create(bindings_path).expect("create OpenGL bindings");

    Registry::new(
        Api::Gl,
        (3, 3),
        Profile::Core,
        Fallbacks::All,
        [
            "GL_ARB_blend_func_extended",
            "GL_KHR_robustness",
            "GL_KHR_debug",
        ],
    )
    .write_bindings(GlobalGenerator, &mut bindings)
    .expect("generate OpenGL bindings");

    println!("cargo:rerun-if-changed=../../vendor/alacritty/alacritty/src/renderer");
}
