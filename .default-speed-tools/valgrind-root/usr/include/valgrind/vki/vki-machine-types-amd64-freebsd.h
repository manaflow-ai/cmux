
/*--------------------------------------------------------------------*/
/*--- x86/FreeBSD-specific kernel interface: posix types.          ---*/
/*---                                 vki_posixtypes-x86-freebsd.h ---*/
/*--------------------------------------------------------------------*/

/*
   This file is part of Valgrind, a dynamic binary instrumentation
   framework.

   Copyright (C) 2000-2005 Julian Seward
      jseward@acm.org
   Copyright (C) 2018-2021 Paul Floyd
      pjfloyd@wanadoo.fr

   This program is free software; you can redistribute it and/or
   modify it under the terms of the GNU General Public License as
   published by the Free Software Foundation; either version 2 of the
   License, or (at your option) any later version.

   This program is distributed in the hope that it will be useful, but
   WITHOUT ANY WARRANTY; without even the implied warranty of
   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
   General Public License for more details.

   You should have received a copy of the GNU General Public License
   along with this program; if not, see <http://www.gnu.org/licenses/>.

   The GNU General Public License is contained in the file COPYING.
*/

#ifndef VKI_MACHINE_TYPES_AMD64_FREEBSD_H
#define VKI_MACHINE_TYPES_AMD64_FREEBSD_H

//----------------------------------------------------------------------
// From sys/i386/include/_types.h
//----------------------------------------------------------------------

typedef __signed char   vki_int8_t;
typedef unsigned char   vki_uint8_t;
typedef short     vki_int16_t;
typedef unsigned short  vki_uint16_t;
typedef int    vki_int32_t;
typedef unsigned int vki_uint32_t;
typedef long      vki_int64_t;
typedef unsigned long   vki_uint64_t;
typedef unsigned long   vki_uintptr_t;
typedef long      vki_intptr_t;


typedef  unsigned int   __vki_clock_t;
typedef  unsigned int   __vki_cpumask_t;
typedef char *    __vki_caddr_t;    /* QQQ 32 on 64 */
typedef  double      __vki_double_t;
typedef  double      __vki_float_t;
typedef  vki_int64_t __vki_intfptr_t;
typedef  vki_int64_t __vki_intmax_t;
typedef  vki_int64_t __vki_ptrdiff_t;
typedef  vki_int64_t __vki_register_t;
typedef  vki_int64_t __vki_segsz_t;
typedef  vki_uint64_t   __vki_size_t;
typedef  vki_int64_t __vki_ssize_t;
typedef  vki_int64_t __vki_time_t;
typedef  vki_uint64_t   __vki_uintfptr_t;
typedef  vki_uint64_t   __vki_uintmax_t;
typedef  vki_uint64_t   __vki_u_register_t;
typedef  vki_uint64_t   __vki_vm_offset_t;
typedef  vki_int64_t __vki_vm_ooffset_t;
typedef  vki_uint64_t   __vki_vm_paddr_t; /* QQQ int64 for PAE */
typedef  vki_uint64_t   __vki_vm_pindex_t;
typedef  vki_uint64_t   __vki_vm_size_t;

#endif // VKI_MACHINE_TYPES_AMD64_FREEBSD_H

/*--------------------------------------------------------------------*/
/*--- end                                                          ---*/
/*--------------------------------------------------------------------*/
